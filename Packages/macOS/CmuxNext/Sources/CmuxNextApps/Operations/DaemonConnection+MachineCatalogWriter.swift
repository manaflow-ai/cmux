public import CmuxNextDaemon

extension DaemonConnection: MachineCatalogWriter {
    /// Publishes on this connection's negotiated ready transport, with no legacy fallback.
    /// - Parameter request: An immutable owner-fenced snapshot.
    /// - Throws: Unsupported, untrusted, wrong-owner, cancelled or transport failures.
    public func publishMachineCatalog(_ request: MachineCatalogPublishRequest) async throws {
        _ = try await self.request(request, timeout: .seconds(15))
    }
}
