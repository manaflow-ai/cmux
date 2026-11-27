public import CmuxNextDaemon
public import Observation

/// Home's dock steps while they can still retire the pane Home shows in (the "unknown pane" of the first open,
/// vw4a-ctl-2 and vw4a-div-2-r2, 2026-11-27). On a fresh session Home's page opens in a plain pane, then the dock
/// steps (``HomeDock/ensure(_:store:home:settle:dock:)``) move it into its pinned dock with one `move-tab-to-column`:
/// the daemon makes a new pane for the dock and closes the old one. Until the store applies that move, the window,
/// `snapshot.get` and every action hand out the old pane's id, and an open aimed at it reaches the daemon after the
/// move: "new-frontend-browser-tab failed: unknown pane", and the tab never opens.
///
/// One owner for that pane id: while ``isSettling(store:)`` holds, the app's control topology is settling, so
/// `snapshot.get` reports `loaded: false` and `settling: true` and the control router holds the methods that act on a
/// pane (`ControlRouter.settledLayout`); once the move is applied they get the dock's pane. The app owns one
/// (`AppServices.homeDockSettle`): its launch arms it, `HomeService.ensureHomeWorkspace` begins and ends each ensure's
/// steps, and ``HomeDock`` counts every dock move, the store's Home's and each window Home's.
@MainActor @Observable
public final class HomeDockSettle {
    /// The app's launch armed it before its first window (``armLaunch()``): Home starts after the first frame, and its
    /// first ensure docks its page. Ends with the first ensure's dock steps. A test's services never arm it.
    public private(set) var launchPending = false
    /// The ensure whose dock steps may still move Home's page (its ``HomeEnsureState`` generation): from its
    /// `ensure_home` until its dock steps ended. Nil when none runs.
    public private(set) var steps: Int?
    /// Dock moves sent whose dock the tree does not show yet.
    public private(set) var movesInFlight = 0

    public init() {}

    /// Called once by the app's launch, before its first window.
    public func armLaunch() { launchPending = true }

    public func begin(_ generation: Int) { steps = generation }

    /// `generation`'s dock steps can no longer move Home's page; a newer ensure's steps stay.
    public func end(_ generation: Int) {
        guard steps == generation else { return }
        steps = nil
        launchPending = false
    }

    func moveSent() { movesInFlight += 1 }

    /// The move failed, or the tree shows its dock: it lists the dock's pane, not the one the move closed.
    func moveLanded() { movesInFlight = max(0, movesInFlight - 1) }

    /// Whether Home's dock steps may still move Home's page out of the pane it shows in now: a dock move is in flight,
    /// or dock steps run (or the launch's first ones are due) on a daemon that docks Home and Home's page is not in
    /// its dock yet. Classic Home has no dock.
    public func isSettling(store: DaemonStore) -> Bool {
        if movesInFlight > 0 { return true }
        guard steps != nil || launchPending, !HomeDock.classic else { return false }
        guard store.isLoaded else { return true }
        // Home's ensure runs only with workspace kinds, and docks only with these (`HomeDock.ensure`).
        guard Self.dockCapabilities.allSatisfy({ store.supports($0.rawValue) }) else { return false }
        guard let home = store.workspaces.first(where: { $0.kind == "home" }) else { return true }
        return !HomeDock.pageIsDocked(in: home)
    }

    static let dockCapabilities: [DaemonCapability] = [.workspaceKind, .pageTabs, .dockColumnRole, .tabColumnRespawn]
}
