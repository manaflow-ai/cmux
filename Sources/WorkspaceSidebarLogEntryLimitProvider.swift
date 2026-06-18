import CmuxSidebar
import Foundation

/// App-side conformer for the sidebar-metadata model's log-entry limit seam.
/// Reads the same `UserDefaults.standard` key the legacy
/// `Workspace.appendSidebarLog` read inline (`"sidebarMaxLogEntries"`),
/// returning the raw configured value (or `nil` when unset). The model applies
/// the legacy default of 50 and the `1...500` clamp.
struct WorkspaceSidebarLogEntryLimitProvider: SidebarLogEntryLimitProviding {
    /// The `UserDefaults` instance read for the configured limit; defaults to
    /// `.standard`, matching the legacy inline read. `UserDefaults` is
    /// documented thread-safe, so storing it in a `Sendable` conformer is safe
    /// despite the type not being marked `Sendable`.
    nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var configuredMaxSidebarLogEntries: Int? {
        defaults.object(forKey: "sidebarMaxLogEntries") as? Int
    }
}
