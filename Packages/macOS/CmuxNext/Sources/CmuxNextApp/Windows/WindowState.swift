import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Observation

/// A browser tab that lives only in this app session because the daemon
/// lacks `frontend-browser-tabs-v1`. Not restored after relaunch.
struct LocalBrowserTab: Hashable, Sendable {
    static let prefix = "local-browser:"
    let id: String
    var url: URL?

    static func make(url: URL?) -> LocalBrowserTab {
        LocalBrowserTab(id: prefix + UUID().uuidString.lowercased(), url: url)
    }
}

/// Everything one window owns (architecture.md 1, user requirement
/// 2026-09-29 "each window needs its own state"): the workspace it shows,
/// tab selection per pane, focused pane per workspace, sidebar width and
/// collapse, and screen switcher visibility. No other window reads or
/// writes it; which workspaces the window lists is `WindowRegistry`'s.
/// Outlives its `WindowController` while the window is registered (the last
/// window closed but restorable), and persists in the daemon's `personal`
/// projection keyed by `id`; never part of the shared tree. Focus, sidebar
/// multi-selection and scroll stay in memory (architecture.md 1): focus is
/// `focus`, this window's state machine (plans/cmux-next/focus.md), which
/// owns the focused pane, the last focused pane per workspace and browser
/// focus mode. It reads the selected workspace and tab selection from here.
@Observable
final class WindowState {
    /// Stable id that survives relaunch (the projection record id). Changes
    /// once, when the window opened at launch adopts a restored record.
    private(set) var id: String
    /// `WorkspaceModel.id` of the workspace shown; nil shows the empty
    /// state (the only window, with no workspaces).
    var workspaceID: String?
    /// Machine that holds `workspaceID` (`local` or a Cloud machine id).
    var machineID: String = MachineRegistry.localID
    var selection = TabSelectionMemory()
    /// This window's focus state machine: the only owner of focus, last
    /// focused pane per workspace, and browser focus mode. Never persisted.
    let focus = FocusCoordinator()
    /// Session-only browser tabs per pane (`PaneModel.id`).
    var localBrowserTabs: [String: [LocalBrowserTab]] = [:]
    /// Sidebar width in points (nil = default) and icons-only collapse.
    var sidebarWidth: Double?
    var sidebarCollapsed = false
    /// The screen switcher is shown (kept across workspace switches).
    var showsScreenSwitcher = false

    init(id: String = UUID().uuidString.lowercased(), workspaceID: String? = nil, machineID: String? = nil) {
        self.id = id
        self.workspaceID = workspaceID
        self.machineID = machineID ?? MachineRegistry.localID
    }
}

extension WindowState {
    /// The state saved for one window.
    convenience init(record: WindowRecord) {
        self.init(id: record.id)
        adopt(record)
    }

    /// Takes over a saved window's identity and state (the window opened at
    /// launch, before the saved state could load, becomes that window).
    func adopt(_ record: WindowRecord) {
        id = record.id
        workspaceID = record.workspaceKey?.rawValue
        machineID = record.machine ?? MachineRegistry.localID
        for (pane, tab) in record.selectedTabs { selection.select(tab, in: pane) }
        sidebarWidth = record.sidebarWidth
        sidebarCollapsed = record.sidebarCollapsed
        showsScreenSwitcher = record.showsScreenSwitcher
    }
}
