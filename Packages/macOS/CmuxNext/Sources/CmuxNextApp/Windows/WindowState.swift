import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Observation

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
    /// The workspaces shown side by side, `workspaceID` focused among them (Debug Settings `sidebar.multiView`,
    /// `WindowController.arrangeOnScreen`); nil shows `workspaceID` alone. Persisted in the record.
    var viewSet: WorkspaceViewSet?
    /// The window frame's docked workspaces (Debug Settings `window.dockedWorkspaces`,
    /// plans/cmux-next/docked-workspace-DESIGN.md). Persisted in the record; empty while the prototype is off.
    var docks = WindowDocks()
    /// The workspace the frame's stage shows (W5): `workspaceID` unless that one is docked. Persisted.
    var stageWorkspaceID: String?
    /// The top page this window shows in place of its workspace
    /// (TOP-SECTION-ITEMS-ARE-PAGES); nil shows the workspace. Selecting a
    /// workspace clears it (`showWorkspace(_:)`). Persisted in the record.
    var page: TopPageRoute?
    /// A New Cloud Workspace this window shows until its terminal opens
    /// (`CloudMachineCreation.id`, cx-lu8f): its progress fills the content
    /// area and its sidebar row is selected. A top page still shows over
    /// it; selecting another workspace clears it. In memory only.
    var cloudCreation: UUID?
    /// Workspaces this window showed, most recent first (Switch to Last Used
    /// Workspace, Sort by Last Used). In memory only, at most 64.
    private(set) var workspaceRecency: [String] = []
    /// Machine that holds `workspaceID` (`local` or a Cloud machine id).
    var machineID: String = MachineRegistry.localID
    let selection = TabSelectionMemory()
    /// This window's focus state machine: the only owner of focus, last
    /// focused pane per workspace, and browser focus mode. Never persisted.
    let focus = FocusCoordinator()
    /// Session-only browser tabs per pane (`PaneModel.id`), observed per pane.
    let localBrowserTabs = LocalBrowserTabs()
    /// Sidebar width in points (nil = default); kept while hidden, so the
    /// sidebar comes back at this width.
    var sidebarWidth: Double?
    /// The sidebar is fully hidden (Toggle Sidebar). Per window, persisted.
    var sidebarHidden = false
    /// Profile this window shows (plans/cmux-next/data-model.md 4). Its
    /// sidebar lists only the window's workspaces of this profile.
    var profileID: ProfileID = .defaultProfile {
        didSet { if profileID != oldValue { refreshRoomBrowserProfile() } }
    }
    /// The workspace last shown in each profile, restored on switching back.
    var profileWorkspaces: [ProfileID: String] = [:]
    /// Profiles this window showed, most recent first (the fallback when the
    /// current profile loses its last workspace here).
    var profileRecency: [ProfileID] = []
    /// The browser profile of the room this window shows (its `ProfileModel.browserProfileID`),
    /// changed only when that value changes (`showRoomBrowserProfile`). Tab badges read this, not
    /// `profileID`: a room switch must not wake every tab of every mounted workspace when the
    /// rooms share a browser profile (space-switch-fast).
    private(set) var roomBrowserProfileID: String?

    /// Reads a room's browser profile (the window's controller sets it from the home store).
    @ObservationIgnored var roomBrowserProfileOf: (@MainActor (ProfileID) -> String?)? {
        didSet { refreshRoomBrowserProfile() }
    }

    /// Re-reads the shown room's browser profile: on a room switch (in the same turn) and when the
    /// room's record changes (`WindowController.observeRoom`).
    func refreshRoomBrowserProfile() {
        guard let roomBrowserProfileOf else { return }
        let id = roomBrowserProfileOf(profileID)
        if roomBrowserProfileID != id { roomBrowserProfileID = id }
    }
    /// Durable id of the screen shown in this window's workspace, so a
    /// relaunch returns to it. Persisted.
    var activeScreenID: String?
    /// The focused pane last written to this window's record (or restored
    /// from it), so a focus change saves the record once.
    var savedFocusedPane: String?
    /// The window was saved in full screen and has not entered it again
    /// since the relaunch (`WindowManager.enterRestoredFullScreens`). Saves
    /// keep `full_screen` while it is set.
    var restoresFullScreen = false

    init(id: String = UUID().uuidString.lowercased(), workspaceID: String? = nil, machineID: String? = nil) {
        self.id = id
        self.workspaceID = workspaceID
        self.machineID = machineID ?? MachineRegistry.localID
    }
}

extension WindowState {
    /// Workspace `id` is drawn beside the focused one: in the `sidebar.multiView` set, a shown docked workspace, or
    /// the stage's workspace while a dock has the focus (`window.dockedWorkspaces`).
    func isOnScreenBeside(_ id: String) -> Bool {
        viewSet?.contains(id) == true
            || (LayoutTunables.dockedWorkspaces.value && (docks.visible.contains { $0.workspace == id } || stageWorkspaceID == id))
    }

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
        viewSet = record.multiView.flatMap(WorkspaceViewSet.init(record:)).flatMap { Set($0.ids).count == $0.ids.count ? $0 : nil }
        docks = WindowDocks(record: record)
        stageWorkspaceID = record.stageKey?.rawValue
        machineID = record.machine ?? MachineRegistry.localID
        for (pane, tab) in record.selectedTabs { selection.select(tab, in: pane) }
        sidebarWidth = record.sidebarWidth
        sidebarHidden = record.sidebarHidden
        activeScreenID = record.screenID?.rawValue
        savedFocusedPane = record.focusedPane
        restoresFullScreen = record.isFullScreen
        if let workspaceID, let pane = record.focusedPane { focus.send(.restoredPane(pane, workspace: workspaceID)) }
        for (workspace, pane) in record.focusedPanes.sorted(by: { $0.key < $1.key }) where workspace != workspaceID {
            focus.send(.restoredPane(pane, workspace: workspace))
        }
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
    /// Unless `keepsCreation` (a repair, or the creation's own workspace,
    /// kept until it is mirrored), another workspace also ends the window's
    /// Cloud creation view; the creation goes on in its sidebar row.
    func showWorkspace(_ id: String?, keepsCreation: Bool = true) {
        workspaceID = id
        if id != nil { page = nil }
        if !keepsCreation, id != nil { cloudCreation = nil }
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
