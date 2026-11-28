import Foundation

/// This Mac's storage card's words (`MachineStorage.xcstrings`). The daemon's refusals are shown
/// in its own words.
nonisolated struct MachineStorageStrings {
    static var title: String {
        String(localized: "machineStorage.title", defaultValue: "Storage on This Mac", table: "MachineStorage", bundle: .module)
    }

    /// One "label: value" line.
    static func line(_ label: String, _ value: String) -> String {
        String(format: String(localized: "machineStorage.line", defaultValue: "%1$@: %2$@", table: "MachineStorage", bundle: .module),
               label, value)
    }

    static var disk: String {
        String(localized: "machineStorage.disk", defaultValue: "Disk", table: "MachineStorage", bundle: .module)
    }

    /// The free bytes and the disk's size, both already formatted ("120 GB free of 994 GB").
    static func free(_ available: String, of total: String) -> String {
        String(format: String(localized: "machineStorage.free", defaultValue: "%1$@ free of %2$@", table: "MachineStorage", bundle: .module),
               available, total)
    }

    static var reclaimable: String {
        String(localized: "machineStorage.reclaimable", defaultValue: "Reclaimable", table: "MachineStorage", bundle: .module)
    }

    static var kept: String {
        String(localized: "machineStorage.kept", defaultValue: "Worktrees kept", table: "MachineStorage", bundle: .module)
    }

    static var toClean: String {
        String(localized: "machineStorage.toClean", defaultValue: "Worktrees to clean up", table: "MachineStorage", bundle: .module)
    }

    static var lastCleanup: String {
        String(localized: "machineStorage.lastCleanup", defaultValue: "Last cleanup", table: "MachineStorage", bundle: .module)
    }

    static var noCleanupYet: String {
        String(localized: "machineStorage.noCleanupYet", defaultValue: "None since the session service started", table: "MachineStorage", bundle: .module)
    }

    static var automatic: String {
        String(localized: "machineStorage.automatic", defaultValue: "Automatic cleanup", table: "MachineStorage", bundle: .module)
    }

    static var on: String {
        String(localized: "machineStorage.on", defaultValue: "On", table: "MachineStorage", bundle: .module)
    }

    static var off: String {
        String(localized: "machineStorage.off", defaultValue: "Off", table: "MachineStorage", bundle: .module)
    }

    static var measuring: String {
        String(localized: "machineStorage.measuring", defaultValue: "Measuring worktrees…", table: "MachineStorage", bundle: .module)
    }

    static var cleaning: String {
        String(localized: "machineStorage.cleaning", defaultValue: "Cleaning up…", table: "MachineStorage", bundle: .module)
    }

    /// What Clean up now freed, already formatted ("Freed 4.2 GB").
    static func freed(_ bytes: String) -> String {
        String(format: String(localized: "machineStorage.freed", defaultValue: "Freed %@", table: "MachineStorage", bundle: .module), bytes)
    }

    static var safety: String {
        String(localized: "machineStorage.safety",
               defaultValue: "Work that lives only on this Mac is archived first, and a cleaned-up worktree comes back when its session opens.",
               table: "MachineStorage", bundle: .module)
    }

    static var cleanUpNow: String {
        String(localized: "machineStorage.cleanUpNow", defaultValue: "Clean up now", table: "MachineStorage", bundle: .module)
    }

    static var done: String {
        String(localized: "machineStorage.done", defaultValue: "Done", table: "MachineStorage", bundle: .module)
    }

    static var unreachable: String {
        String(localized: "machineStorage.unreachable", defaultValue: "The session service on this Mac did not answer.",
               table: "MachineStorage", bundle: .module)
    }
}
