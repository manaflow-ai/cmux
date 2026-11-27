import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextHomeEngine
import Observation

/// Home's dock steps while they can still retire the pane Home shows in (the "unknown pane" of the first open,
/// vw4a-ctl-2 and vw4a-div-2-r2, 2026-11-27). On a fresh session Home's page opens in a plain pane, then the dock
/// steps (`HomeDock.ensure`) move it into its pinned dock with one `move-tab-to-column`: the daemon makes a new pane
/// for the dock and closes the old one. Until the store applies that move, the window, `snapshot.get` and every
/// action hand out the old pane's id, and an open aimed at it reaches the daemon after the move: "new-frontend-browser-
/// tab failed: unknown pane", and the tab never opens.
///
/// One owner for that pane id: while ``isSettling(store:)`` holds, `snapshot.get` reports `loaded: false` (and
/// `settling: true`) and the control router holds actions that act on a pane (`ControlRouter.settledLayout`), so no
/// caller is given a pane the dock move retires; once the move is applied they get the dock's pane. Owned by
/// `AppServices`; armed by the app's launch, written by `HomeService.ensureHomeWorkspace` and every dock move
/// (``AppServices/homeDockMove(_:_:_:_:_:)``).
@Observable @MainActor
final class HomeDockSettle {
    /// The app's launch armed it before its first window (``armLaunch()``): Home starts after the first frame, and
    /// its first ensure docks its page. Ends with the first ensure's dock steps. A test's services never arm it.
    private(set) var launchPending = false
    /// The ensure whose dock steps may still move Home's page (its `HomeEnsureState` generation): from its
    /// `ensure_home` until its dock move was applied or it ended without one. Nil when none runs.
    private(set) var steps: Int?
    /// Dock moves sent and not yet applied by the store. A move of an ensure a newer one cancelled still counts: the
    /// cancel does not take the move back (launch runs the ensure again on sign-in and on the Chief owner's connect).
    private(set) var movesInFlight = 0

    /// Called once by the app's launch, before its first window.
    func armLaunch() { launchPending = true }

    func begin(_ generation: Int) { steps = generation }

    /// `generation`'s dock steps can no longer move Home's page; a newer ensure's steps stay.
    func end(_ generation: Int) {
        guard steps == generation else { return }
        steps = nil
        launchPending = false
    }

    /// `done` for one dock move, counted in flight from now until `landed` returned (the store applied the daemon's
    /// reply to it, so the tree lists the dock's pane and no longer the one the move closed).
    func tracking(_ done: @escaping @MainActor (Bool) -> Void,
                  landed: @escaping @MainActor () async -> Void) -> @MainActor (Bool) -> Void {
        movesInFlight += 1
        return { [self] moved in
            // task-owner: one wait for the store to apply the move's reply (event-driven, bounded by the store's liveness)
            Task { @MainActor in
                if moved { await landed() }
                self.movesInFlight = max(0, self.movesInFlight - 1)
                done(moved)
            }
        }
    }

    /// Whether Home's dock steps may still move Home's page out of the pane it shows in now: a dock move is in flight,
    /// or dock steps run (or the launch's first ones are due) on a daemon that docks Home and Home's page is not in
    /// its dock yet. Classic Home has no dock.
    func isSettling(store: DaemonStore) -> Bool {
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

extension AppServices {
    /// Home's dock move (`HomeDock.Dock`), for the store's Home and each window's: the tab into a new left chat dock
    /// (`TabMoves.toNewDockColumn`), counted by ``homeDockSettle`` until the store applied its reply.
    func homeDockMove(_ tab: TabModel, _ anchor: PaneModel, _ respawn: SplitRespawn?, _ pinned: Bool,
                      _ done: @escaping @MainActor (Bool) -> Void) {
        let service = daemon, connection = daemon.connection
        let completion = homeDockSettle.tracking(done) {
            if let connection { await service.appliedThroughReply(on: connection, after: "home dock move") }
        }
        TabMoves.toNewDockColumn(tab, anchor: anchor, edge: .left, role: .agentChat, respawn: respawn, pinned: pinned,
                                 services: self, completion: completion)
    }
}
