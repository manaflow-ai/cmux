public import CmuxNextDaemon
public import CmuxNextWakeups

/// What ``WindowHomes`` needs of the app's windows and daemon: one-line forwards (`AppServices`).
@MainActor
public protocol WindowHomeHost: AnyObject {
    /// The store's home workspace, once the store reported it.
    var windowHomeStoreHome: WorkspaceModel? { get }
    /// The local daemon's connection and store.
    var windowHomeConnection: DaemonConnection? { get }
    var windowHomeStore: DaemonStore { get }
    /// The app's main-thread work scheduler (``HomeDock/ensure`` waits for the tree on it).
    var windowHomeWork: MainWorkScheduler { get }
    /// Returns once the local store applied every event before `connection`'s last reply.
    func windowHomeApplied(_ connection: DaemonConnection) async
    /// The workspaces window `window` lists, and the open window that lists `workspace`.
    func windowHomeMembers(_ window: String) -> [String]
    func windowHomeOpenOwner(of workspace: String) -> String?
    /// Whether window `window` is registered and open, and each registered window's workspaces.
    func windowHomeIsOpen(_ window: String) -> Bool
    var windowHomeWindows: [String: [String]] { get }
    /// Closes `workspace` on its daemon (a window Home its window no longer has a place for).
    func windowHomeClose(_ workspace: String)
    func windowHomeWorkspace(_ id: String) -> WorkspaceModel?
    /// The space (room) window `window` shows (rooms, data-model.md 3); nil for a window this app does not have.
    func windowHomeRoom(_ window: String) -> ProfileID?
    /// Shows `workspace` in window `window`, taking it there; never in another window.
    func windowHomeShow(_ workspace: String, in window: String)
    /// Claims the workspace about to be made for `window`, or drops that claim.
    func windowHomeClaim(_ workspace: String, window: String)
    func windowHomeDropClaim(_ workspace: String)
    /// Runs `create` with `workspace` held out of its window until its first tab shows.
    func windowHomeHold(_ workspace: String, _ create: () async throws -> Bool?) async throws
    /// The app's move of a tab into a new left chat dock (``HomeDock/Dock``).
    func windowHomeDock(_ tab: TabModel, _ anchor: PaneModel, _ respawn: SplitRespawn?, _ pinned: Bool,
                        _ done: @escaping @MainActor (Bool) -> Void)
}
