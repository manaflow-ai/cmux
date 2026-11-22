import Foundation

extension MachineSectionRow {
    /// The state word the Machines page shows for this row (Resources/AddMachine.xcstrings), public so the
    /// sidebar's Hosts section says the same thing.
    public var stateWord: String {
        if failed { return Self.word("machines.failed", "Failed") }
        switch serverState {
        case .paused: return Self.word("machines.paused", "Paused")
        case .resuming: return Self.word("machines.resuming", "Resuming…")
        case .failed: return Self.word("machines.failed", "Failed")
        case .deleted: return Self.word("machines.deleted", "Deleted")
        case nil: break
        }
        if isConnecting { return Self.word("machines.connecting", "Connecting…") }
        return isConnected ? Self.word("machines.connected", "Connected") : Self.word("machines.offline", "Offline")
    }

    private static func word(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "AddMachine", bundle: .module)
    }
}
