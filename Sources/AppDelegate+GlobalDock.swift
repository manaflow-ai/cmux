import AppKit
import CmuxTerminal

/// App-wide Global Dock.
///
/// A single `DockSplitStore` whose live panels (terminals/browsers) persist
/// across every workspace and window for the app's lifetime. The right-sidebar
/// Dock panel mounts this store directly.
extension AppDelegate {
    /// Stable owner id for the Global Dock's panels. This is NOT a real
    /// workspace id — cross-container moves resolve a reference window via the
    /// active main window instead (see ``dockReferenceTabManager(for:)``).
    static let globalDockWorkspaceId = UUID(uuidString: "D0CCD0CC-0000-4000-8000-000000000001")!

    private static var _globalDock: DockSplitStore?

    /// Whether `id` is the Global Dock's synthetic owner id.
    static func isGlobalDockOwnerId(_ id: UUID) -> Bool { id == globalDockWorkspaceId }

    /// The app-wide Global Dock, created on first access and retained for the
    /// app's lifetime (never torn down on workspace close). Seeded from
    /// `~/.config/cmux/dock.json` with a home base directory.
    var globalDock: DockSplitStore {
        if let existing = Self._globalDock { return existing }
        let store = DockSplitStore(
            workspaceId: Self.globalDockWorkspaceId,
            scope: .global,
            baseDirectoryProvider: { nil },
            remoteBrowserSettingsProvider: { .local }
        )
        Self._globalDock = store
        return store
    }

    /// Whether the Global Dock has been created (so callers can avoid lazily
    /// constructing it just to look something up).
    var hasGlobalDock: Bool { Self._globalDock != nil }

    /// The Global Dock if it already exists, without creating it.
    var existingGlobalDock: DockSplitStore? { Self._globalDock }

    /// Resolves the `TabManager` a Dock's cross-container moves should target.
    /// A Workspace Dock maps to its owning workspace's window; the Global Dock
    /// has no home workspace, so it uses the currently active main window.
    func dockReferenceTabManager(for dock: DockSplitStore) -> TabManager? {
        if dock.scope == .global {
            return preferredRegisteredMainWindowContext()?.tabManager
        }
        return tabManagerFor(tabId: dock.workspaceId)
    }
}
