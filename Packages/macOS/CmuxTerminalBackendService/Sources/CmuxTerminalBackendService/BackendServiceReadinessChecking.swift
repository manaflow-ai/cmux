/// Verifies that an eligible launch agent is serving the expected backend protocol.
public protocol BackendServiceReadinessChecking: Sendable {
    /// Connects to the backend and returns its validated protocol identity.
    ///
    /// - Returns: A proof tied to the running daemon and topology snapshot.
    /// - Throws: A transport, protocol, identity, or deadline error.
    func checkReadiness(
        trustedPair: BackendServiceInstalledPair
    ) async throws -> BackendServiceReadiness
}
