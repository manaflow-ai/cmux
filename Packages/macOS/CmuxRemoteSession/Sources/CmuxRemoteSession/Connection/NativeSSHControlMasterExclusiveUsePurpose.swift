/// The operation requesting exclusive use of a resolved ControlMaster socket.
enum NativeSSHControlMasterExclusiveUsePurpose {
    case reverseForwardRecovery
    case ordinaryCleanup
}
