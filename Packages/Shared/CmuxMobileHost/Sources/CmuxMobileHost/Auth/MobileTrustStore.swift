/// The Mac's mirror of the account trust store (seam for B6).
public protocol MobileTrustStore: Sendable {
    func device(install: String) async -> PairedDevice?
    /// Installs revoked from now on, each once. The host closes their sessions.
    func revocations() async -> AsyncStream<String>
}
