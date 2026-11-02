import CmuxNextDaemon
import CmuxNextHomeEngine

// Each window's own Home (cmux#27880, `WindowHomes`): one-line forwards to the App's owners.
extension AppServices: WindowHomeHost {
    var windowHomeStoreHome: WorkspaceModel? { home.homeWorkspace }
    var windowHomeConnection: DaemonConnection? { daemon.connection }
    var windowHomeStore: DaemonStore { daemon.store }
    func windowHomeApplied(_ connection: DaemonConnection) async { _ = await daemon.appliedThroughReply(on: connection, after: "create window home") }
    func windowHomeMembers(_ window: String) -> [String] { windows.registry.members(of: window) }
    func windowHomeOpenOwner(of workspace: String) -> String? { windows.openOwner(of: workspace) }
    func windowHomeIsOpen(_ window: String) -> Bool { windows.registry.value.window(window)?.isOpen == true }
    var windowHomeWindows: [String: [String]] { windows.membersByWindow }
    func windowHomeClose(_ workspace: String) { windows.discard([workspace]) }
    func windowHomeWorkspace(_ id: String) -> WorkspaceModel? { workspace(id: id) }
    func windowHomeShow(_ workspace: String, in window: String) { windows.show(workspaceID: workspace, inWindow: window) }
    func windowHomeClaim(_ workspace: String, window: String) { windows.claimNew(workspaceID: workspace, window: window) }
    func windowHomeDropClaim(_ workspace: String) { windows.claims.pending[workspace] = nil }
    func windowHomeHold(_ workspace: String, _ create: () async throws -> Bool?) async throws { _ = try await FirstTabHold.creating(workspace, windows: windows, create) }
    func windowHomeDock(_ tab: TabModel, _ anchor: PaneModel, _ respawn: SplitRespawn?, _ pinned: Bool, _ done: @escaping @MainActor (Bool) -> Void) { TabMoves.toNewDockColumn(tab, anchor: anchor, edge: .left, role: .agentChat, respawn: respawn, pinned: pinned, services: self, completion: done) }
}
