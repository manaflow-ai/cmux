/// Admission for phones (default deny). `TrustStoreAuthorizer` is the
/// implementation; tests and later lanes may wrap it.
public protocol MobileDeviceAuthorizer: Sendable {
    /// A hello on a link session: the device proves possession of its paired key.
    func authorize(_ request: DeviceAuthRequest) async -> Result<MobileDevicePrincipal, MobileAuthFailure>
    /// An op `HostDO` forwarded: the socket layer authenticated `install`, the
    /// Mac still checks that it is a paired device of this account.
    func authorizeForwarded(install: String, userID: String?) async -> Result<MobileDevicePrincipal, MobileAuthFailure>
    /// Installs revoked from now on.
    func revocations() async -> AsyncStream<String>
}
