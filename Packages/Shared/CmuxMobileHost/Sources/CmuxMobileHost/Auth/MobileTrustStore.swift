/// The Mac's mirror of the account trust store (seam for B6).
public protocol MobileTrustStore: Sendable {
    func device(install: String) async -> PairedDevice?
    /// Installs revoked from now on, each once. The host closes their sessions.
    /// A store marks the device revoked before it yields, so an admission
    /// that reads the store after the yield is refused.
    func revocations() async -> AsyncStream<String>
}
