/// Tracks process ownership of exact cmux-owned SSH master sockets.
protocol NativeSSHControlMasterOwnershipTracking: Sendable {
    func retain(
        controlPath: String,
        lease: NativeSSHControlMasterLeaseIdentity
    ) -> Bool
    func release(lease: NativeSSHControlMasterLeaseIdentity)
    func beginRecovery(
        controlPath: String
    ) -> NativeSSHControlMasterExclusiveUseAuthorization?
    func beginCleanup(
        controlPath: String
    ) -> NativeSSHControlMasterExclusiveUseAuthorization?
}
