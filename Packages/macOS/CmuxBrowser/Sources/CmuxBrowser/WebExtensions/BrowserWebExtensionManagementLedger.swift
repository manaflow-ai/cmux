/// Versioned per-profile extension management state.
public struct BrowserWebExtensionManagementLedger: Codable, Equatable, Sendable {
    /// Current on-disk schema version.
    public static let currentSchemaVersion = 1

    /// Schema version used to decode and migrate the ledger.
    public var schemaVersion: Int

    /// Explicitly approved extensions keyed by stable logical identity.
    public var records: [String: BrowserWebExtensionManagedRecord]

    /// Creates an extension-management ledger.
    public init(
        schemaVersion: Int = currentSchemaVersion,
        records: [String: BrowserWebExtensionManagedRecord] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.records = records
    }
}
