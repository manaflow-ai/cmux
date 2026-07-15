/// Cross-platform settings boundary implemented by each app's Iroh composition root.
@MainActor
public protocol CmxIrohSettingsControlling: AnyObject {
    /// Returns a credential-free snapshot suitable for display and diagnostics.
    func irohSettingsSnapshot() async -> CmxIrohSettingsSnapshot

    /// Emits snapshot changes without polling.
    func irohSettingsUpdates() -> AsyncStream<CmxIrohSettingsSnapshot>

    /// Persists the account-level relay preference and safely rebuilds the endpoint.
    func setIrohRelayPreference(_ preference: CmxIrohRelayPreferenceDraft) async throws

    /// Creates or updates account-visible custom relay metadata and a device-local secret.
    func upsertIrohCustomRelay(
        _ relay: CmxIrohCustomRelayDraft,
        deviceSecret: String?
    ) async throws

    /// Removes custom relay metadata and erases this device's associated secret.
    func removeIrohCustomRelay(id: String) async throws

    /// Probes one custom relay without changing the active preference.
    func testIrohCustomRelay(id: String) async -> CmxIrohRelayTestResult

    /// Fetches the latest signed fleet and account preference.
    func refreshIrohSettings() async
}
