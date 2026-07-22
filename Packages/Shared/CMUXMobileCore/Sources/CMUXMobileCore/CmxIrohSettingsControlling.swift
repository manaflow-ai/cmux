public import Foundation

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

    /// Persists one device-local custom private-path configuration.
    func upsertIrohCustomPrivatePath(_ path: CmxIrohCustomPrivatePathDraft) async throws

    /// Removes this device's custom private paths for one Mac.
    func removeIrohCustomPrivatePath(macDeviceID: String) async throws

    /// Fetches the latest signed fleet and account preference.
    func refreshIrohSettings() async

    /// Returns the bounded, credential-free connection timeline for this app process.
    func irohDiagnosticReport() async -> DiagnosticReport

    /// Exports the same bounded report without terminal contents or network identities.
    func exportIrohDiagnosticReport() async -> Data

    /// Erases the in-memory connection timeline and rotates its report session.
    func clearIrohDiagnosticReport() async
}

public extension CmxIrohSettingsControlling {
    func upsertIrohCustomPrivatePath(_ path: CmxIrohCustomPrivatePathDraft) async throws {
        throw CmxIrohSettingsControlError.unsupported
    }

    func removeIrohCustomPrivatePath(macDeviceID: String) async throws {
        throw CmxIrohSettingsControlError.unsupported
    }

    func irohDiagnosticReport() async -> DiagnosticReport {
        .empty
    }

    func exportIrohDiagnosticReport() async -> Data {
        Data()
    }

    func clearIrohDiagnosticReport() async {}
}

public enum CmxIrohSettingsControlError: Error, Equatable, Sendable {
    case unsupported
}
