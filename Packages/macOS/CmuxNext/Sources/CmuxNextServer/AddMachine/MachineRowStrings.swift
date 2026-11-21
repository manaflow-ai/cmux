import Foundation

/// The machine state words the Machines page shows (Resources/AddMachine.xcstrings), public so the
/// sidebar's Hosts section says the same thing.
public nonisolated enum MachineRowStrings {
    public static var connected: String { s("machines.connected", "Connected") }
    public static var connecting: String { s("machines.connecting", "Connecting…") }
    public static var offline: String { s("machines.offline", "Offline") }
    public static var paused: String { s("machines.paused", "Paused") }
    public static var resuming: String { s("machines.resuming", "Resuming…") }
    public static var failed: String { s("machines.failed", "Failed") }
    public static var deleted: String { s("machines.deleted", "Deleted") }

    private static func s(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "AddMachine", bundle: .module)
    }
}
