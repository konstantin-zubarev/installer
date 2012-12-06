#!/bin/bash
#
# Copyright (C) 2012 FOSS Group
#                    Germany
#                    http://www.foss-group.de
#                    support@foss-group.de
#
# Authors:
#  Christian Affolter <christian.affolter@stepping-stone.ch>
#  
# Licensed under the EUPL, Version 1.1 or – as soon they
# will be approved by the European Commission - subsequent
# versions of the EUPL (the "Licence");
# You may not use this work except in compliance with the
# Licence.
# You may obtain a copy of the Licence at:
#
# http://www.osor.eu/eupl
#
# Unless required by applicable law or agreed to in
# writing, software distributed under the Licence is
# distributed on an "AS IS" basis,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
# express or implied.
# See the Licence for the specific language governing
# permissions and limitations under the Licence.
#
# 
#

MKDIR_CMD=${MKDIR_CMD:="/bin/mkdir"}
MOUNT_CMD=${MOUNT_CMD:="/bin/mount"}
TAR_CMD=${TAR_CMD:="/bin/tar"}
REBOOT_CMD=${REBOOT_CMD:="/sbin/reboot"}
XZ_CMD=${XZ_CMD:="/usr/bin/xz"}
IP_CMD=${IP_CMD:="/sbin/ip"}
CHROOT_CMD=${CHROOT_CMD:="/bin/chroot"}
LN_CMD=${LN_CMD:="/bin/ln"}
RC_UPDATE_CMD=${RC_UPDATE_CMD:="/sbin/rc-update"}
BASENAME_CMD=${BASENAME_CMD:="/bin/basename"}

LIB_DIR=${LIB_DIR:="`dirname $0`"}

source "${LIB_DIR}/device.lib.sh"
source "${LIB_DIR}/filesystem.lib.sh"
source "${LIB_DIR}/input-output.lib.sh"
source "${LIB_DIR}/input-validation.lib.sh"
source "${LIB_DIR}/input-validation_network.lib.sh"
source "${LIB_DIR}/lvm.lib.sh"
source "${LIB_DIR}/memory.lib.sh"
source "${LIB_DIR}/cpu.lib.sh"
source "${LIB_DIR}/validate.lib.sh"
source "${LIB_DIR}/grub.lib.sh"
source "${LIB_DIR}/openssh.lib.sh"


function welcomeMessage ()
{
    header "Welcome to the ${osbdProjectName}-Installer"

    info "The installer comes WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,"
    info "either expressed or implied."
    info ""
    info "Do you want to start the installation?"
    if ! yesInput; then
        die
    fi

    info ""
    info "OK, going to start"
}

function checkCPU ()
{
    header "CPU Requirements"
    info "A 64bit x86 CPU with virtualization extension is required\n"

    local cpuVendorId="`cpuGetVendorId`"
    local cpuModelName="`cpuGetModelName`"

    case $cpuVendorId in
        GenuineIntel)
            info 'Detected an "Intel" CPU'
            ;;

        AuthenticAMD)
            info 'Detected an "AMD" CPU'
            warning "${osbdProjectName} wasn't tested on \"AMD\" CPUs"
            ;;

        *)
            info "Detected a \"${cpuVendorId}\" CPU"
            error "Your CPU \"${cpuModelName}\" is not supported."
            error 'You need an "Intel" or "AMD" CPU'
            die
    esac


    if ! cpuHasVirtualizationSupport; then
        error 'Your CPU misses support for the virtualization extension'
        error 'You need a CPU with either the "Intel VT" or "AMD-V" extension'
        info  ''
        info  "If your CPU has virtualization support it might be disabled in the BIOS"
        die
    fi

    info "Your CPU \"${cpuModelName}\" is supported"

}

function checkAvailableMemory ()
{
  header "Memory Requirements"
  info "At least ${osbdMemoryMinimalSpace} GB of physical memory is required."
  
  local availableMemory=`memoryGetTotalInGb`

  if test $availableMemory -lt ${osbdMemoryMinimalSpace}; then
      error "You don't have enough memory (${availableMemory} GB)."
      die
  fi

  info "You have enough memory to continue (${availableMemory} GB)."
}

function nodeTypeSelection ()
{
    header "Node Type Selection"
    info "The Installer supports three different types of nodes:"
    info ""
    info "-  The Single-Server which lets you quickly install and test the"
    info "   ${osbdProjectName} on a single machine"
    info ""
    info "-  The VM-Node which runs the virtual machines"
    info ""
    info "-  The Storage-Node which holds all data images of the virtual machines"
    info ""
    info "Please enter the number of the node type you would like to install"
    info "${osbdNodeTypeDemoSystem}) Single-Server"
    info "${osbdNodeTypeVmNode}) VM-Node"
    info "${osbdNodeTypeStorageNode}) Storage-Node"
     
    readVarAndValidateInList "osbdNodeType" "Node type" \
        "${osbdNodeTypeDemoSystem} ${osbdNodeTypeStorageNode} ${osbdNodeTypeVmNode}"
}


function installationDeviceSelection ()
{
    header "Installation Device Selection"
    info "A dedicated SCSI, SATA or PATA disk is required for the installation"
    info "The disk has to be at least $osbdDiskMinimalSpace GB in size\n"

    local availableDevices=`deviceListAllBlockDevices '^(s|h)d[a-z]$'`

    if test -z "$availableDevices"; then
        error "No supported devices are available for installation"
        error "Please insert a SCSI, SATA or PATA disk and restart the installer"
        die
    fi

    local device=""

    for device in $availableDevices; do
        local deviceSize=`deviceGetBlockDeviceSizeGB $device`

        if test $deviceSize -ge $osbdDiskMinimalSpace; then
            info "Found $device ($deviceSize GB). Size is OK"
            finalDevices="$finalDevices $device"
        else
            info "Found $device ($deviceSize GB). Size is too small, skipping"
        fi
    done

    if test -z "$finalDevices"; then
        error "None of the available devices has enough disk space"
        die
    fi

    info ""
    info "Below you will find a list of all detected and supported disks"
    local device=""
    for device in $finalDevices; do
        info "$device (`deviceGetBlockDeviceSizeGB $device` GB)"
    done

    info ""
    info "Please enter the device name on which you would like to install"
    readVarAndValidateInList "osbdInstallDevice" "Device" "$finalDevices"
    osbdInstallDevicePath="/dev/${osbdInstallDevice}"
    info "'${osbdInstallDevice}' will be used as the installation device."
}


function dataDeviceSelection ()
{
    header "Data Device Selection"
    info "You're installing a storage node and have more than one disk present."
    info ""
    info "Would you like to store the VM images on a secondary disk?"
    info "Also say yes here if you need more than 2 TB of storage space."
    info ""

    osbdUseSecondaryDisk="no"

    if ! yesInput; then
        # no need for a secondary disk, exit
        return 0    
    fi

    info ""
    info "Below you will find a list of the remaining supported disks"
    local device=""
    for device in ${finalDevices}; do
        info "$device (`deviceGetBlockDeviceSizeGB $device` GB)"
    done

    info ""
    info "Please enter the name of the device which you would like to use"
    readVarAndValidateInList "osbdDataDevice" "Device" "${finalDevices}"
    osbdDataDevicePath="/dev/${osbdDataDevice}"
    osbdUseSecondaryDisk="yes"
    debug "osbdUseSecondaryDisk: ${osbdUseSecondaryDisk}"
    info "'${osbdDataDevice}' will be used as the data device."
}


function deviceSelection ()
{
    finalDevices=""

    installationDeviceSelection "$finalDevices"

    # remove the primary disk from the list of available disks
    # and cast to an array to easily get the number of devices/entries 
    finalDevices=( ${finalDevices/${osbdInstallDevice}/} )

    # Only ask for secondary disks, if there are some devices left and the
    # installation is for a storge node
    if [ ${#finalDevices[@]} -eq 0 -o \
         ${osbdNodeType} -ne ${osbdNodeTypeStorageNode} ];
    then
        # exit secondary device selection
        return 0
    fi

    # recast back to a string of words
    finalDevices="${finalDevices[*]}"

    dataDeviceSelection "$finalDevices"

    unset finalDevices
}


function installationDevicePartitioning ()
{
    header "Installation Device Partitioning"

    devicePartitionClearing "${osbdInstallDevicePath}"

    debug "Creating the new partition layout on $osbdInstallDevicePath"
    if ! deviceCreateOsbdPartitionLayout $osbdInstallDevicePath; then
        error "Unable to create the new partition layout"
        die
    fi

    info ""
    info "Device partitioning was successful"

}


function dataDevicePartitioning ()
{
    header "Data Device Partitioning"

    devicePartitionClearing "${osbdDataDevicePath}"

    info ""
    info "Device partitioning was successful"

}

function devicePartitionClearing ()
{
    local devicePath="$1"

    info "Below is the existing partition layout of your selected device\n"
    devicePrintPartitionTable $devicePath

    info ""
    info "All existing partitions have to be deleted in order to continue"
    info "THIS MEANS THAT ALL DATA ON THIS DISK WILL BE LOST"
    info "Do you want to continue?"
    if ! yesInput; then
        die
    fi


    debug "Erasing the partition table on $devicePath"
    if ! deviceErasePartitionTable "$devicePath"; then
        error "Unable to erase the partition table"
        die
    fi
}


function devicePartitioning ()
{
    installationDevicePartitioning
   
    debug "osbdUseSecondaryDisk: ${osbdUseSecondaryDisk}"
    if [ "${osbdUseSecondaryDisk}" = "yes" ]; then
        dataDevicePartitioning
    fi
}


function createLvmOsbdVolume ()
{
    local size=$1
    local name=$2
    local volumeGroup=$3

    if ! lvmCreateVolume "$size" "$name" "$volumeGroup"; then
        error "Unable to create LVM volume ${name}"
        die
    fi
}

function createLvmOsbdVolumeSizeInExtends ()
{
    local extents=$1
    local name=$2
    local volumeGroup=$3

    if ! lvmCreateVolumeSizeInExtends "$extents" "$name" "$volumeGroup"; then
        error "Unable to create LVM volume ${name}"
        die
    fi
}


function lvmCleanup ()
{
    header "Logical Volume Cleanup and Preparation"
    info "Checking for existing volume groups and physical volumes"

    # Set a liberal LVM device filter to get all existing physical volumes
    local deviceFilterLiberal='/dev/(s|h)d[a-z][0-9]*'

    debug "Setting a liberal LVM device filter: '${deviceFilterLiberal}'"
    if ! lvmConfigSetDeviceFilter "${deviceFilterLiberal}"; then
       error "Unable to set the LVM device filter"
       die
    fi

    debug "LVM initialization"
    if ! $LVM_VGSCAN_CMD > /dev/null; then
        error "Unable to scan the LVM volume groups"
        die
    fi

    # deactivate all existing volume groups
    if ! $LVM_VGCHANGE_CMD -a n > /dev/null; then
        error "Unable to deactivate the LVM volume groups"
        die
    fi

    # Getting existing related physical volumes, in order to deal with leftovers
    # from a previously (faild) installation
    debug "Getting existing ${osbdProjectName} related LVM physical volumes"
    local vgs="${osbdLvmVolumeGroup0} ${osbdLvmVolumeGroup1}"

    for vg in $vgs; do
        debug "Search for physical volumes related to volume group ${vg}"
        pvs=`lvmGetPhysicalVolumesByVolumeGroup ${vg}`

        if [ -z "$pvs" ]; then 
            debug "No PVs found which belong to '${vg}'"
            continue # skip to next VG
        fi

        info ""
        info "Found existing ${osbdProjectName} related physical volumes for"
        info "volume group ${vg}:"
        info "${pvs}"
        info ""
        info "Those are most likely leftovers from a previous installation"
        info "In order to continue those volume groups and physical volumes"
        info "have to be removed"
        info "THIS MEANS THAT ALL LVM META DATA WILL BE LOST"

        info "Do you want to continue?"
        if ! yesInput; then
            die    
        fi

        # remove volume group
        if ! $LVM_VGREMOVE_CMD --force $vg > /dev/null; then
            error "Unable to remove the LVM volume group"
            die
        fi

        # remove all pvs
        local pv=""
        for pv in "${pvs}"; do
            debug "Wiping LVM label on ${pv}"
            if ! $LVM_PVREMOVE_CMD --force $pv > /dev/null; then
                error "Unable to wipe the LVM label on device '${pv}'"
                die
            fi
        done
    done
}

function lvmSetup ()
{
    header "Logical Volume Setup"
    info "Setup LVM environment and volumes"

    osbdLvmPV0="${osbdInstallDevicePath}5"
    debug "LVM Physical Volume 0: $osbdLvmPV0"

    local deviceFilter="$osbdLvmPV0"

    # If the user has chosen a secondary disk for the data storage on a
    # storage node, we create a secondary physical volume
    if [ "${osbdUseSecondaryDisk}" = "yes" ]; then
        osbdLvmPV1="${osbdDataDevicePath}"
        debug "LVM Physical Volume 1: $osbdLvmPV1"

        # or'ing both devices for the LVM filter
        local deviceFilter="${deviceFilter}|${osbdLvmPV1}"
    else
       # otherwise we want the data logical volume to be created on the same 
       # logical volume group afterwards
       osbdLvmVolumeGroup1="${osbdLvmVolumeGroup0}"
    fi

    debug "Setting LVM device filter: '${deviceFilter}'"
    if ! lvmConfigSetDeviceFilter "${deviceFilter}"; then
       error "Unable to set the LVM device filter"
       die
    fi

    debug "LVM initialization"
    if ! $LVM_VGSCAN_CMD > /dev/null; then
        error "Unable to scan the LVM volume groups"
        die
    fi

    sleep 2

    # setup the OS related volumes
    lvmVolumeGroupSetup "$osbdLvmPV0" "$osbdLvmVolumeGroup0"
    lvmOsVolumesSetup

    # setup the Data volume for a storage node
    if [ ${osbdNodeType} -eq ${osbdNodeTypeStorageNode} ]; then

        # If a secondary LVM physical volume was created before, we
        # also have to create a secondary volume group
        if [ -n "${osbdLvmPV1}" ]; then
            lvmVolumeGroupSetup "$osbdLvmPV1" "$osbdLvmVolumeGroup1"
        fi

        lvmDataVolumesSetup
    fi


    info ""
    info "All LVM volumes created successfully"
}


function lvmVolumeGroupSetup ()
{
    local devicePath="$1"
    local volumeGroup="$2"

    debug "Creating physical volume on $devicePath"
    if ! $LVM_PVCREATE_CMD -ff --zero y --yes "${devicePath}" > /dev/null;
    then
        error "Unable to create the LVM physical volume '${devicePath}'"
        die
    fi

    if ! $LVM_VGCREATE_CMD "$volumeGroup" "${devicePath}";
    then
        error "Unable to create the LVM volume group '$volumeGroup'"
        die
    fi
}

function lvmOsVolumesSetup ()
{
    createLvmOsbdVolume "500M" "home"    "$osbdLvmVolumeGroup0"
    createLvmOsbdVolume "3G"   "var"     "$osbdLvmVolumeGroup0"
    createLvmOsbdVolume "1G"   "tmp"     "$osbdLvmVolumeGroup0"
    createLvmOsbdVolume "1G"   "portage" "$osbdLvmVolumeGroup0"

    if [ ${osbdNodeType} -eq ${osbdNodeTypeDemoSystem} ]; then
        createLvmOsbdVolumeSizeInExtends \
            "100%FREE" "virtualization" "$osbdLvmVolumeGroup0"
    fi
}

function lvmDataVolumesSetup ()
{
    createLvmOsbdVolumeSizeInExtends \
        "100%FREE" "${osbdGlusterVolumeName}" "$osbdLvmVolumeGroup1"
}

function createOsbdFilesystem ()
{
    local label="${osbFilesystemLabelPrefix}_$1"
    local device="$2"

    debug "Creating filesystem for device '${device}' with label '${label}'"

    if ! filesystemCreateXfs "$label" "$device" "force";
    then
        error "Unable to create XFS filesystem on ${device}"
        die
    fi
}

function filesystemSetup ()
{
    header "Filesystem Creation"
    info "Creating filesystems"

    osbdSwapDevice="${osbdInstallDevicePath}2"
    debug "OSBD swap device: ${osbdSwapDevice}"

    if ! filesystemCreateSwap "${osbFilesystemLabelPrefix}_swap" \
                              "$osbdSwapDevice" "force";
    then
        error "Unable to create swap on ${osbdSwapDevice}"
        die
    fi

    createOsbdFilesystem "boot"    "${osbdInstallDevicePath}1"
    createOsbdFilesystem "root"    "${osbdInstallDevicePath}3"
    createOsbdFilesystem "home"    "/dev/${osbdLvmVolumeGroup0}/home"
    createOsbdFilesystem "portage" "/dev/${osbdLvmVolumeGroup0}/portage"
    createOsbdFilesystem "tmp"     "/dev/${osbdLvmVolumeGroup0}/tmp"
    createOsbdFilesystem "var"     "/dev/${osbdLvmVolumeGroup0}/var"

    case "${osbdNodeType}" in
        ${osbdNodeTypeDemoSystem})
            createOsbdFilesystem "virtual" \
                "/dev/${osbdLvmVolumeGroup0}/virtualization"
        ;;

        ${osbdNodeTypeStorageNode})
            createOsbdFilesystem "gfs-01" \
               "/dev/${osbdLvmVolumeGroup1}/${osbdGlusterVolumeName}"
        ;;
    esac


    info ""
    info "Filesystem creation was successful"
}

function mountOsbdPartition ()
{
    local label="${osbFilesystemLabelPrefix}_$1"
    local mountPoint="$2"

    if ! $MKDIR_CMD -p "$mountPoint"; then
        error "Unable to create mount point ${mountPoint}"
        die
    fi

    if ! $MOUNT_CMD -L "$label" "$mountPoint"; then
        error "Unable to mount device with label '${label}' to ${mountPoint}"
        die
    fi

    debug "Device with label '${label}' successfully mounted to ${mountPoint}"
}

function mountPartitions ()
{
    header "Mounting Filesystems"

    mountOsbdPartition "root"    "${osbdRootMount}" 
    mountOsbdPartition "boot"    "${osbdRootMount}/boot" 
    mountOsbdPartition "home"    "${osbdRootMount}/home" 
    mountOsbdPartition "var"     "${osbdRootMount}/var" 
    mountOsbdPartition "tmp"     "${osbdRootMount}/tmp" 
    mountOsbdPartition "portage" "${osbdRootMount}/usr/portage" 

    case "${osbdNodeType}" in
        ${osbdNodeTypeDemoSystem})
            mountOsbdPartition "virtual" "${osbdRootMount}/var/virtualization"
            ;;

        ${osbdNodeTypeStorageNode})
            mountOsbdPartition \
                "gfs-01" "${osbdRootMount}/var/data/gluster-volume-01"
            ;;
    esac


    info "Mounting of filesystems was successful"
}

function unpackStage4Tarball ()
{
    header "Stage4 Installation"

    info "Unpacking stage4 tarball"
    info "This will take a while - please be patient"

    if ! cd $osbdRootMount; then
        error "Unable to change working directory to $osbdRootMount"
        die
    fi
   
    if ! $TAR_CMD -xjpf $osbdStage4Tarball; then
        error "Unable to unpack stage4 tarball"
        die
    fi

    info ""
    info "Unpacking of stage4 tarball was successful"
}

function setNodeType ()
{
    case "${osbdNodeType}" in
        ${osbdNodeTypeDemoSystem})
            local nodeTypeName='demo'
        ;;

        ${osbdNodeTypeStorageNode})
            local nodeTypeName='storage'
        ;;

        ${osbdNodeTypeVmNode})
            local nodeTypeName='vm'
        ;;
    esac

    if ! echo "${nodeTypeName}" > ${osbdNodeTypeFilePath}; then
        error "Unable to write node type name to ${osbdNodeTypeFilePath}"
        die
    fi
}

function fstabCreation ()
{
   local fstabPath="${osbdRootMount}/etc/fstab"

   debug "Creating fstab: ${fstabPath}"

    cat << EOF > "${fstabPath}"
# /etc/fstab: static file system information.
#
# noatime turns off atimes for increased performance (atimes normally aren't 
# needed; notail increases performance of ReiserFS (at the expense of storage 
# efficiency).  It's safe to drop the noatime options if you want and to 
# switch between notail / tail freely.
#
# The root filesystem should have a pass number of either 0 or 1.
# All other filesystems should have a pass number of 0 or greater than 1.
#
# See the manpage fstab(5) for more information.
#

# <fs>                  <mountpoint>        <type>    <opts>              <dump/pass>

# NOTE: If your BOOT partition is ReiserFS, add the notail option to opts.
LABEL=OSBD_boot     /boot                 xfs      noauto,noatime               1 2
LABEL=OSBD_root     /                     xfs      noatime                      0 1
LABEL=OSBD_swap     none                  swap     sw                           0 0
LABEL=OSBD_var      /var                  xfs      noatime,nodev,nosuid         0 2
LABEL=OSBD_tmp      /tmp                  xfs      noatime,nodev,nosuid,noexec  0 2
LABEL=OSBD_home     /home                 xfs      noatime,nodev                0 2
LABEL=OSBD_portage  /usr/portage          xfs      noatime,nodev,nosuid,noexec  0 2
EOF

    if [ ${osbdNodeType} -eq ${osbdNodeTypeDemoSystem} ]; then
        debug "Creating fstab entry: /var/virtualization"

        cat << EOF >> "${fstabPath}"
LABEL=OSBD_virtual  /var/virtualization   xfs      noatime,nodev,nosuid         0 2
EOF
    fi


    if [ ${osbdNodeType} -eq ${osbdNodeTypeStorageNode} ]; then
        debug "Creating fstab entry: /var/data/gluster-volume-01"

        cat << EOF >> "${fstabPath}"
LABEL=OSBD_gfs-01     /var/data/gluster-volume-01  xfs      noatime,nodev,nosuid,rw      0 2
EOF
    fi


    debug "Creating fstab entry for cdrom and shm"
    cat << EOF >> "${fstabPath}"
/dev/cdrom          /mnt/cdrom            auto     noauto,ro                    0 0

# glibc 2.2 and above expects tmpfs to be mounted at /dev/shm for 
# POSIX shared memory (shm_open, shm_unlink).
# (tmpfs is a dynamically expandable/shrinkable ramdisk, and will
#  use almost no memory if not populated with files)
shm                     /dev/shm        tmpfs           nodev,nosuid,noexec         0 0

EOF

}

function bootLoaderInstallation ()
{
    header "Boot Loader Installation"

    info "Detecting the grub boot partition name"
    local bootPartition=`grubDetectBootPartition "$osbdBootPartitionMagicFile"`
    if test $? -ne 0; then 
        error "Unable to detect the grub boot partition name"
        die
    fi
    
    debug "Grub boot partition name: $bootPartition"

    info "Installing grub into master boot record"
    if ! grubSetup "${bootPartition}" '(hd0)'; then
        error "Unable to install grub into MBR"
        die
    fi

    if ! grubConfigChangeRootPartition "${osbdGrubConfig}" "${bootPartition}";
    then
        error "Unable to change the grub root partition in the grub config"
        die
    fi

    info ""
    info "Boot loader installation was successful"
}

function networkDeviceSelection ()
{
    header "Network Device Selection"

    # Cast to an array to easily get the number of devices/entries 
    declare -a availableDevices
    local availableDevices=( `deviceListAllEthernetInterfaces` )

    if [ ${osbdNodeType} -eq ${osbdNodeTypeDemoSystem} ]; then
        # one network card is sufficient for demo systems
        osbdNetworkMinimalDevices=1
    else
        info "Two or more ethernet network interfaces are required"
        info "Both devices will be aggregated (bonded) to one logical link"
    fi

    if [ ${#availableDevices[@]} -eq 0 ]; then
        error "No ethernet devices are available"
        error "Please insert ethernet interface cards and restart the installer"
        die
    fi
    
    if [ ${#availableDevices[@]} -lt ${osbdNetworkMinimalDevices} ]; then
        local additionalDevices=$(( ${osbdNetworkMinimalDevices} - ${#availableDevices[@]} ))
        error "Only ${#availableDevices[@]} ethernet device(s) present"
        error "Please insert $additionalDevices additional ethernet card(s)"
        die
    fi

    local device=""

    #info ""
    #info "Below you will find a list of all detected ethernet devices"
    #local device=""
    #for device in ${availableDevices[@]}; do
    #    info ""
    #    info "${device}:"
    #${IP_CMD} link show ${device}
    #done


    info ""
    if [ ${osbdNodeType} -eq ${osbdNodeTypeDemoSystem} ]; then
        info "Please enter the device which you would like to use"
    else
        info "Please enter the devices which you would like to add to the"
        info "link aggregation group"
    fi

    info ""

    local i=0
    while [ ${#availableDevices[@]} -gt 0 ]; do
        info "Available ethernet devices: ${availableDevices[*]}"
        readVarAndValidateInList "nic" "Device #${i}" "${availableDevices[*]}"
        osbdNetworkDevices[$i]="$nic"

        # remove assigned device from the list for the next run
        availableDevices=( ${availableDevices[*]/${nic}/} )
        unset nic

        if [ ${osbdNodeType} -eq ${osbdNodeTypeDemoSystem} ]; then
            # one interface is enough for demo systems
            break
        fi

        if [ ${#osbdNetworkDevices[@]} -ge 2 -a ${#availableDevices[@]} -ne 0 ] 
        then
            info ""
            info "Would you like to add an additional network interface?"
            if ! yesInput; then
                break
            fi
        fi

        let i++
   done

   debug "Using ${osbdNetworkDevices[*]} for bond0"
}


function networkConfiguration ()
{
    header "Network Configuration"

    declare -a osbdNetworkNames

    declare -A osbdNetworkVlanId
    declare -A osbdNetworkDomain
    declare -A osbdNetworkIpAddress
    declare -A osbdNetworkNetmask
    declare -A osbdNetworkBroadcastAddress

    declare -a osbdNetworkDnsResolver

    osbdNetworkNames=('pub' 'admin' 'data' 'int')

    if [ ${osbdNodeType} -eq ${osbdNodeTypeDemoSystem} ]; then
        # Pre-define pseudo network configuration values for all interfaces
        # on demo system installations
        osbdNetworkNames+=('vmbr') # add the local vmbr interface 

        for network in ${osbdNetworkNames[@]}; do
            osbdNetworkVlanId[${network}]=${osbdNetworkDemoSystemVlanId[${network}]}
            osbdNetworkDomain[${network}]=${osbdNetworkDemoSystemDomain[${network}]}
            osbdNetworkIpAddress[${network}]=${osbdNetworkDemoSystemIpAddress[${network}]}
            osbdNetworkNetmask[${network}]=${osbdNetworkDemoSystemNetmask[${network}]}
            osbdNetworkBroadcastAddress[${network}]=${osbdNetworkDemoSystemBroadcastAddress[${network}]}
        done

        info "Do you want to use automatic network configuration (via DHCP)?"
        if yesInput; then
            info "OK, going to use automatic configuration (DHCP)"
            osbdNetworkHostName="${osbdNetworkDemoSystemHostName}"
            osbdNetworkDefaultGateway="${osbdNetworkDemoSystemDefaultGateway}"
            writeDynamicNetworkConfiguration
            writeStaticNetworkBridgingConfiguration
            return 0
        else
            info "OK, you will have to configure your network manually"
        fi
    fi

    local networkInputOk="no"

    until [ "$networkInputOk" = "yes" ]; do
        osbdNetworkHostName=""

        readNetworkHostName

        if [ ${osbdNodeType} -eq ${osbdNodeTypeDemoSystem} ]; then
            # On demo system only ask for a pub network configuration as the
            # other networks were pre-defined with pseudo values befor.
            readStaticNetworkConfiguration 'pub'
        else 
            # On all other node types the user has to provide the required
            # network configuration for all networks.
            local networkName=""
            for networkName in ${osbdNetworkNames[@]}; do
                readStaticNetworkConfiguration "${networkName}"
            done
        fi

        readNetworkDefaultGateway
        readNetworkDnsResolver

        info ""
        info "Below you see the overal network configuration:"
        displayNetworkHostName
        info ""

        if [ ${osbdNodeType} -eq ${osbdNodeTypeDemoSystem} ]; then
            # On demo installations only display the pub network configuration
            # as the other (pre-defined) networks may confuse the user.
            displayNetworkConfiguration 'pub'
        else
            # On all other nodes, display all network configuration
            for networkName in ${osbdNetworkNames[@]}; do
                displayNetworkConfiguration ${networkName}
            done
        fi

        displayNetworkDnsResolver
        info ""
        displayNetworkDefaultGateway

        info ""
        info "Is the above configuration correct?"
        if yesInput; then
            local networkInputOk="yes"
        else
            info "Reseting network configuration\n"
        fi
    done

    writeStaticNetworkConfiguration
}

function displayNetworkConfiguration ()
{
    local networkName="$1"

    local prefix="${osbdNetworkIpAddress[${networkName}]}/${osbdNetworkNetmask[${networkName}]}"

    info "<< '${networkName}' Network >>"
    if [ ${osbdNodeType} -ne ${osbdNodeTypeDemoSystem} ]; then
        info "VLAN ID:          ${osbdNetworkVlanId[${networkName}]}"
    fi
    info "Domain name:      ${osbdNetworkDomain[${networkName}]}"
    info "IP address/mask:  ${prefix}"
    info "Broadcast:        ${osbdNetworkBroadcastAddress[${networkName}]}"
    info ""
}

function displayNetworkHostName {

    info "<< Host Name >>"
    info "Host name:  ${osbdNetworkHostName}"
}

function displayNetworkDnsResolver {
    local dnsResolver

    info "<< DNS Resolvers >>"
    for dnsResolver in ${osbdNetworkDnsResolver[@]}; do
        info "DNS Resolver:     $dnsResolver"
    done
}

function displayNetworkDefaultGateway {

    info "<< Default Gateway >>"
    info "Default Gateway:  ${osbdNetworkDefaultGateway}"
}

function writeNetworkDnsResolver {
    # add the static name server configuration
    echo "# Generated by the ${osbdProjectName}-Installer" \
        > $osbdNetworkResolverConfig

    local dnsResolver
    for dnsResolver in ${osbdNetworkDnsResolver[@]}; do
        echo "nameserver ${dnsResolver}" >> $osbdNetworkResolverConfig
    done
}

function readNetworkHostName ()
{
    header "Network Host Name Configuration"
    info "Please enter the host name for your node (without the domain)"
    readVarAndValidateHostName "osbdNetworkHostName"
}

function readNetworkDefaultGateway ()
{
    header "Network Default Gateway Configuration"
    info "Please enter the IP address of your default gateway"
    info "(usually the first IP address in your pub network"
    readVarAndValidateIpAddress "osbdNetworkDefaultGateway"
}

function readNetworkDnsResolver ()
{
    header "Network DNS Resolver Configuration"

    local i=1
    while [ $i -le 3 ]; do
        info ""
        info "Please enter the IP address of your local DNS resolver #${i}"
        readVarAndValidateIpAddress "ipAddress"
        osbdNetworkDnsResolver[${i}]="$ipAddress"
        unset ipAddress

        if [ $i -eq 3 ]; then
            break
        fi

        info ""
        info "Would you like to configure an additional DNS resolver?"
        if ! yesInput; then
            break
        fi

        let i++
    done
}


function readStaticNetworkConfiguration ()
{
    local networkName="$1"

    header "Network Configuration for the '${networkName}' Network"

    local inputOK="no"

    until [ "$inputOk" = "yes" ]; do
        if [ ${osbdNodeType} -eq ${osbdNodeTypeDemoSystem} ] && \
           [ "${networkName}" = 'pub' ]
        then
            # Simply use the default and don't ask the user on demo system
            # installations.
            osbdNetworkVlanId[pub]=${osbdNetworkDemoSystemVlanId[pub]};
        else
            info "Please enter the VLAN ID for the '${networkName}' interface"
            readVarAndValidateVlanId "vlanId"
            osbdNetworkVlanId[${networkName}]="$vlanId"
            unset vlanId
        fi

        info "Please enter the domain name for the '${networkName}' interface"
        readVarAndValidateDomainName "domainName"
        osbdNetworkDomain[${networkName}]="$domainName"
        unset domainName

        info "Please enter the IP address which should be assigned to the '${networkName}' interface"
        readVarAndValidateIpAddress "ipAddress"
        osbdNetworkIpAddress[${networkName}]="$ipAddress"
        unset ipAddress

        info ""
        info "Please enter the corresponding network mask in the CIDR format"
        info "For example you have to enter 24 for 255.255.255.0"
        readVarAndValidateCidrNetmask "netmask"
        osbdNetworkNetmask[${networkName}]="$netmask"
        unset netmask

        info ""
        info "Please enter the broadcast IP address"
        info "(usually the last IP address in your network block)"
        readVarAndValidateIpAddress "broadcastAddress" "Broadcast IP address"
        osbdNetworkBroadcastAddress[${networkName}]="$broadcastAddress"
        unset broadcastAddress

        info ""
        info "Below you see the current configuration for the '${networkName}' network:"
        displayNetworkConfiguration "${networkName}"

        info ""
        info "Is the above configuration correct?"
        if yesInput; then
            local inputOk="yes"
        else
            info "Reseting network configuration\n"
        fi
    done
}

function writeDynamicNetworkConfiguration ()
{
    cat << EOF > $osbdNetworkConfig
#-----------------------------------------------------------------------------
# Physical interfaces
config_${osbdNetworkDev}="dhcp"
dhcp_${osbdNetworkDev}="nontp nonis"
EOF

    if test $? -ne 0; then
        error "Unable to write the network configuration to $osbdNetworkConfig"
        die
    fi

    writePostInstallNetworkConfig
}

function writeStaticNetworkConfiguration ()
{
    writeStaticNetworkPhysicalConfiguration

    if [ ${osbdNodeType} -ne ${osbdNodeTypeDemoSystem} ]; then
        # Configure bonding and VLANs only on vm- and storage-nodes
        writeStaticNetworkBondingConfiguration
        writeStaticNetworkVlanConfiguration
    fi

    if [ ${osbdNodeType} -ne ${osbdNodeTypeStorageNode} ]; then
        # Configure bridging only on vm- and demo-nodes
        writeStaticNetworkBridgingConfiguration
    fi

    writeNetworkDnsResolver
    writeNetworkHostName
    writeNetworkOpenSSHConfiguration
    writePostInstallNetworkConfig
}


function writeStaticNetworkPhysicalConfiguration ()
{
    # Configure the physical ethernet interfaces
    cat << EOF > $osbdNetworkConfig
#-----------------------------------------------------------------------------
# Physical interfaces
EOF

    if test $? -ne 0; then
        error "Unable to write the network configuration to $osbdNetworkConfig"
        die
    fi

    
    local i=1
    for physicalInterface in ${osbdNetworkDevices[@]}; do
        addNetworkInitSymlink "${physicalInterface}"

        echo "#physical interface #${i}" >> $osbdNetworkConfig

        if [ ${osbdNodeType} -eq ${osbdNodeTypeDemoSystem} ]; then
            # On demo-systems add the pub network configuration to the first
            # physical interface
            local ip=${osbdNetworkIpAddress[pub]}
            local mask=${osbdNetworkNetmask[pub]}
            local brd=${osbdNetworkBroadcastAddress[pub]}
            local gw=${osbdNetworkDefaultGateway}
            local domain=${osbdNetworkDomain[pub]}
            local host=${osbdNetworkHostName}

            echo "config_${physicalInterface}=\"${ip}/${mask} brd ${brd}\"" \
                >> $osbdNetworkConfig

            echo "routes_${physicalInterface}=\"default via ${gw}\"" \
                >> $osbdNetworkConfig

            writeHostFileEntry "${ip}  ${host}.${domain} ${host}"

        else
            # All other nodes use the physical interface as a bonding member
            # port, so no IP configuration will be done.
            echo "config_${physicalInterface}=\"null\""   >> $osbdNetworkConfig
        fi

        echo "" >> $osbdNetworkConfig
        let i++
    done
}

function writeStaticNetworkBondingConfiguration ()
{
    # Enslave all physical interfaces to an IEEE 802.3ad dynamic 
    # link aggregation bond
    cat << EOF >> $osbdNetworkConfig

#-----------------------------------------------------------------------------
# Bonding interfaces

slaves_bond0="${osbdNetworkDevices[*]}"
lacp_rate_bond0="fast"
miimon_bond0="100"
mode_bond0="802.3ad"
 
config_bond0="null"

EOF

    if test $? -ne 0; then
        error "Unable to write the network configuration to $osbdNetworkConfig"
        die
    fi

    addNetworkInitSymlink "bond0"
    addServiceToRunLevel "net.bond0"
}


function writeStaticNetworkVlanConfiguration ()
{
    # Create VLAN interfaces on top of the bonding interface
    cat << EOF >> $osbdNetworkConfig

#-----------------------------------------------------------------------------
# VLAN (802.1q support)
 
vlans_bond0="${osbdNetworkVlanId[*]}"

EOF

    local gw=${osbdNetworkDefaultGateway}

    # generating vlan interface configuration
    local network=""
    for network in ${osbdNetworkNames[@]}; do

        local vlanId=${osbdNetworkVlanId[${network}]}
        local ip=${osbdNetworkIpAddress[${network}]}
        local mask=${osbdNetworkNetmask[${network}]}
        local brd=${osbdNetworkBroadcastAddress[${network}]}
        local domain=${osbdNetworkDomain[${network}]}
        local host=${osbdNetworkHostName}

        echo "#${network} VLAN"                          >> $osbdNetworkConfig
        echo "vlan${vlanId}_name=\"vlan${vlanId}\""      >> $osbdNetworkConfig


        if [ "$network" = "pub" -a ${osbdNodeType} -eq ${osbdNodeTypeVmNode} ]
        then
            # VM nodes have the pub vlan bridged with vmbr0, so no
            # configuration will be done on the vlan interface
            echo "config_vlan${vlanId}=\"null\"" >> $osbdNetworkConfig
        else
            echo "config_vlan${vlanId}=\"${ip}/${mask} brd ${brd}\"" \
                >> $osbdNetworkConfig
        fi

        if [ "$network" = "pub" \
             -a ${osbdNodeType} -eq ${osbdNodeTypeStorageNode} ]
        then
            # Append the default gateway to the public network.
            # VM nodes will have it on the bridging interface
            # (see below) and not directly on the VLAN interface.
            # This should be more flexible in the future as the default
            # gateway may be on a different network.
            echo "routes_vlan${vlanId}=\"default via ${gw}\"" \
                    >> $osbdNetworkConfig
        fi

        echo "" >> $osbdNetworkConfig

        if [ "$network" = "int" ]; then
            writeHostFileEntry "${ip}  ${host}.${domain} ${host}"
        else
            writeHostFileEntry "${ip}  ${host}.${domain}"
        fi
        
    done
}


function writeStaticNetworkBridgingConfiguration ()
{
    # Create an IEEE 802.1d bridge and configure 
    cat << EOF >> $osbdNetworkConfig

#-----------------------------------------------------------------------------
# Bridging (802.1d) interfaces
EOF
    if test $? -ne 0; then
        error "Unable to write the network configuration to $osbdNetworkConfig"
        die
    fi

    if [ ${osbdNodeType} -eq ${osbdNodeTypeVmNode} ]; then
        local network='pub'

    elif [ ${osbdNodeType} -eq ${osbdNodeTypeDemoSystem} ]; then
        local network='vmbr'
    fi 

    local vlanId=${osbdNetworkVlanId[${network}]}
    local ip=${osbdNetworkIpAddress[${network}]}
    local mask=${osbdNetworkNetmask[${network}]}
    local brd=${osbdNetworkBroadcastAddress[${network}]}
    local gw=${osbdNetworkDefaultGateway}


    if [ ${osbdNodeType} -eq ${osbdNodeTypeVmNode} ]; then
        # Add the vlan pub interface to the bridge
        echo "bridge_vmbr0=\"vlan${vlanId}\"" >> $osbdNetworkConfig 

    elif [ ${osbdNodeType} -eq ${osbdNodeTypeDemoSystem} ]; then
        # Create an empty isolated bridge on demo systems
        echo 'brctl_vmbr0=""' >> $osbdNetworkConfig
    fi

    echo "config_vmbr0=\"${ip}/${mask} brd ${brd}\"" >> $osbdNetworkConfig 

    if [ ${osbdNodeType} -eq ${osbdNodeTypeVmNode} ]; then
        echo "routes_vmbr0=\"default via ${gw}\"" >> $osbdNetworkConfig
    fi

    addNetworkInitSymlink "vmbr0"
    addServiceToRunLevel "net.vmbr0"
}

function writeHostFileEntry ()
{
    local entry="$1"

    if ! echo "$entry" >> ${osbdNetworkHostFile}; then
        error "Unable to write host file entry to ${osbdNetworkHostFile}"
        die
    fi
}

function writePostInstallNetworkConfig ()
{
    # Creates the post install network configuration CSV file, which will be
    # used by the node integration scripts after the first boot
    local gw=${osbdNetworkDefaultGateway}

    local network=""
    for network in ${osbdNetworkNames[@]}; do

        if [ "$network" = 'vmbr' ]; then
            # Skip the internal 'vmbr' network, which is present on demo systems
            continue;
        fi

        local vlanId=${osbdNetworkVlanId[${network}]}
        local ip=${osbdNetworkIpAddress[${network}]}
        local mask=${osbdNetworkNetmask[${network}]}
        local brd=${osbdNetworkBroadcastAddress[${network}]}
        local domain=${osbdNetworkDomain[${network}]}
        local host=${osbdNetworkHostName}

        # write post-install network config
        local sp="${osbdNetworkPostInstallConfigValueSeparator}"
        local netConfig="${host}${sp}${network}${sp}${vlanId}${sp}${ip}${sp}"
        netConfig="${netConfig}${domain}${sp}${mask}${sp}${brd}${sp}" 

        if [ "$network" = "pub" ]; then
            # Append the default gateway to the public network
            # This should be more flexible in the future as the default gateway
            # may be on a different network.
            netConfig="${netConfig}${gw}"
        fi

        echo $netConfig >> ${osbdNetworkPostInstallConfigPath}

        if test $? -ne 0; then
            error "Unable to write post-install network config entry"
            die
        fi
    done
}

function writeNetworkOpenSSHConfiguration ()
{
    if [ ${osbdNodeType} -eq ${osbdNodeTypeDemoSystem} ]; then
        # On demo nodes only one (public) interface is present
        local opensshListenConfig="ListenAddress ${osbdNetworkIpAddress[pub]}"
    else
        # On multi node installations listen on the 'admin' interface for
        # interactive SSH remote access and on the 'int' interface for
        # inter-node communication.
        local opensshListenConfig="ListenAddress ${osbdNetworkIpAddress[admin]}\nListenAddress ${osbdNetworkIpAddress[int]}"
    fi
        
    if ! opensshReplaceConfigPattern \
            "<FOSS-CLOUD-LISTEN-ADDRESS-CONFIG>" \
            "${opensshListenConfig}" \
            "${osbdNetworkOpenSSHDaemonConfig}";
    then
        error "Unable to change OpenSSH listening address"
        die
    fi

}

function writeNetworkHostName ()
{
    echo "hostname=\"${osbdNetworkHostName}\"" > $osbdNetworkHostNameFile

    if test $? -ne 0; then
        error "Unable to write the host name  to $osbdNetworkHostNameFile"
        die
    fi
}

function addNetworkInitSymlink ()
{
    local interface=$1
    local initDir='/etc/init.d'

    debug "Adding ${interface} init script symlink"

    $CHROOT_CMD ${osbdRootMount} \
        $LN_CMD --force --symbolic \
        ${initDir}/net.lo ${initDir}/net.${interface}

    if test $? -ne 0; then
        error "Unable to set symbolic init script link for ${interface}"
    fi
}

function addServiceToRunLevel ()
{
    local service="$1"
    local runlevel="$2"

    if [ -z "$runlevel" ]; then
        local runlevel='default'
    fi

    debug "Adding ${service} to ${runlevel}"

    $CHROOT_CMD ${osbdRootMount} \
        ${RC_UPDATE_CMD} add ${service} ${runlevel} > /dev/null

    if test $? -ne 0; then
        error "Unable to add ${service} to ${runlevel}"
        return 1
    fi

    return 0
}

function finishMessage ()
{
    header "Installation Complete"

    info "Congratulation you have finished the installation of ${osbdProjectName}"
    info "Now all you need to do is reboot the system and remove the CD-ROM"
    info ""
    info "Do you want to reboot your system?"
    if yesInput; then
        info "OK, will reboot now"
        $REBOOT_CMD
    fi

    exit 0
}

function processArguments ()
{
    while getopts ":cmsh" option; do
        case $option in
	    c )
	        osbdSkipCpuCheck="yes"
		debug "Skipping CPU requirement checks"
		;;
	    
	    m )
	        osbdSkipMemoryCheck="yes"
		debug "Skipping memory requirement checks"
		;;

	    s )
	        osbdSkipCpuCheck="yes"
		osbdSkipMemoryCheck="yes"
		debug "Skipping CPU and memory requirement checks"
		;;

	    h )
	        printUsage
		exit 0
		;;
	
	    \? )
	        error "Invalid option '-${OPTARG}' specified"
		printUsage
		die
		;;

	    : )
	        error "Missing argument for '-${OPTARG}'"
		printUsage
		die
		;;
	esac
    done
}

function printUsage ()
{
    cat << EOF
Usage: $( ${BASENAME_CMD} "$0" ) [OPTION]...

  -c			Skip CPU requirement checks
  -m			Skip memory requirement checks
  -s			Skip both, CPU and memory requirement checks
  -h			Display this help and exit
EOF
}


function doOsbdSingleNodeInstall ()
{
    fossCloudLogoWithProgramInfo "$osbdProgramName" "$osbdProgramVersion"

    welcomeMessage

    if [ "$osbdSkipCpuCheck" != "yes" ]; then
        checkCPU
    fi

    if [ "$osbdSkipMemoryCheck" != "yes" ]; then
        checkAvailableMemory
    fi

    nodeTypeSelection
    deviceSelection
    lvmCleanup
    devicePartitioning
    lvmSetup
    filesystemSetup
    mountPartitions
    unpackStage4Tarball
    setNodeType
    fstabCreation
    networkDeviceSelection
    networkConfiguration
    bootLoaderInstallation
    finishMessage
}
