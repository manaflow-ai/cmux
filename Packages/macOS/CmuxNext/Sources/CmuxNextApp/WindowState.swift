import CmuxNextBridge
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

/// Client-local state of one window (architecture.md 1): which workspace it
/// shows, tab selection per pane, and focus. Persisted to the daemon's
/// `personal` projection on settle; never part of the shared tree.
@Observable
final class WindowState {
    /// Stable id that survives relaunch (the projection record id).
    private(set) var id: String
    /// `WorkspaceModel.id` of the workspace shown.
    var workspaceID: String?
    /// Machine that holds `workspaceID` (`local` or a Cloud machine id).
    var machineID: String = MachineRegistry.localID
    var selection = TabSelectionMemory()
    /// Focused layout pane per workspace.
    var focusedPane: [String: LayoutPaneID] = [:]
    /// Session-only browser tabs per pane (`PaneModel.id`).
    var localBrowserTabs: [String: [LocalBrowserTab]] = [:]

    init(id: String = UUID().uuidString.lowercased(), workspaceID: String? = nil, machineID: String? = nil) {
        self.id = id
        self.workspaceID = workspaceID
        self.machineID = machineID ?? MachineRegistry.localID
    }

    /// Takes over a restored record's identity (the window opened before the
    /// saved state could load).
    func adopt(id: String, workspaceID: String?, machineID: String?) {
        self.id = id
        self.workspaceID = workspaceID
        self.machineID = machineID ?? MachineRegistry.localID
    }
}
