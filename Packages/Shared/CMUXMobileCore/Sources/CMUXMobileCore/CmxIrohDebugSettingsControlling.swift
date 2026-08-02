/// Debug-only Iroh controls exposed by a host composition root.
@MainActor
public protocol CmxIrohDebugSettingsControlling: AnyObject {
    /// Persists one path constraint and restarts the active Iroh runtime in place.
    func setIrohDebugTransportVerificationMode(
        _ mode: CmxIrohTransportVerificationMode
    ) async throws
}

public extension CmxIrohDebugSettingsControlling {
    /// Compatibility entrypoint for the existing macOS relay-only toggle.
    func setIrohDebugRelayOnly(_ enabled: Bool) async throws {
        try await setIrohDebugTransportVerificationMode(
            enabled ? .relayOnly : .automatic
        )
    }
}
