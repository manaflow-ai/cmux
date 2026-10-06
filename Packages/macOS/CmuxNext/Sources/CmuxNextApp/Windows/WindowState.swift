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
/// collapse, and the shown screen. No other window reads or
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
    var workspaceID: String? {
        didSet { if workspaceID != oldValue { noteShown(workspaceID, after: oldValue) } }
    }
    /// The top page this window shows in place of its workspace
    /// (TOP-SECTION-ITEMS-ARE-PAGES); nil shows the workspace. Selecting a
    /// workspace clears it (`showWorkspace(_:)`). Persisted in the record.
    var page: TopPageRoute?
    /// Workspaces this window showed, most recent first (Switch to Last Used
    /// Workspace, Sort by Last Used). In memory only, at most 64.
    private(set) var workspaceRecency: [String] = []
    /// Machine that holds `workspaceID` (`local` or a Cloud machine id).
    var machineID: String = MachineRegistry.localID
    var selection = TabSelectionMemory()
    /// This window's focus state machine: the only owner of focus, last
    /// focused pane per workspace, and browser focus mode. Never persisted.
    let focus = FocusCoordinator()
    /// Session-only browser tabs per pane (`PaneModel.id`).
    var localBrowserTabs: [String: [LocalBrowserTab]] = [:]
    /// Sidebar width in points (nil = default); kept while hidden, so the
    /// sidebar comes back at this width.
    var sidebarWidth: Double?
    /// The sidebar is fully hidden (Toggle Sidebar). Per window, persisted.
    var sidebarHidden = false
    /// Profile this window shows (plans/cmux-next/data-model.md 4). Its
    /// sidebar lists only the window's workspaces of this profile.
    var profileID: ProfileID = .defaultProfile
    /// The workspace last shown in each profile, restored on switching back.
    var profileWorkspaces: [ProfileID: String] = [:]
    /// Profiles this window showed, most recent first (the fallback when the
    /// current profile loses its last workspace here).
    var profileRecency: [ProfileID] = []
    /// Durable id of the screen shown in this window's workspace, so a
    /// relaunch returns to it. Persisted.
    var activeScreenID: String?
    /// The focused pane last written to this window's record (or restored
    /// from it), so a focus change saves the record once.
    var savedFocusedPane: String?

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
        page = record.page.flatMap(TopPageRoute.init(rawValue:))
        machineID = record.machine ?? MachineRegistry.localID
        for (pane, tab) in record.selectedTabs { selection.select(tab, in: pane) }
        sidebarWidth = record.sidebarWidth
        sidebarHidden = record.sidebarHidden
        activeScreenID = record.screenID?.rawValue
        savedFocusedPane = record.focusedPane
        profileID = record.profile ?? .defaultProfile
        profileWorkspaces = Dictionary(record.profileWorkspaces.map { (ProfileID(rawValue: $0.key), $0.value.rawValue) },
                                       uniquingKeysWith: { first, _ in first })
        profileRecency = [profileID]
    }

    /// Makes `profile` current, remembering the shown workspace of the
    /// profile it leaves.
    func enterProfile(_ profile: ProfileID) {
        if let workspaceID { profileWorkspaces[profileID] = workspaceID }
        profileID = profile
        profileRecency.removeAll { $0 == profile }
        profileRecency.insert(profile, at: 0)
    }
}

extension WindowState {
    /// Shows `id` (nil: the empty state): the window leaves its top page.
    func showWorkspace(_ id: String?) {
        workspaceID = id
        if id != nil { page = nil }
    }

    /// The workspace shown before the current one, if any.
    var lastUsedWorkspace: String? { workspaceRecency.first { $0 != workspaceID } }

    /// Forgets workspaces this window no longer lists.
    func pruneRecency(keeping members: Set<String>) {
        workspaceRecency.removeAll { !members.contains($0) }
    }

    fileprivate func noteShown(_ id: String?, after previous: String?) {
        guard let id else { return }
        workspaceRecency.removeAll { $0 == id }
        workspaceRecency.insert(id, at: 0)
        if let previous, !workspaceRecency.contains(previous) { workspaceRecency.insert(previous, at: 1) }
        if workspaceRecency.count > 64 { workspaceRecency.removeLast(workspaceRecency.count - 64) }
    }
}
