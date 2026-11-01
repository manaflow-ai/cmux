public import CmuxNextDaemon

/// Split Browser's daemon side, as ``PaneSplitCommand`` is Cmd-D's. With a stand-in the split shows at once, its new
/// pane holding a stand-in browser tab (``ProvisionalTab/browser(url:engine:profile:)``), so the pane and its page draw
/// in the key's frame. No daemon request makes an app-rendered browser in a new split, so the work makes the daemon's
/// tab in the source pane (the caller keeps it unselected and out of that pane's strip) and moves it into the split
/// under the split's transaction. The store takes the pane the tab lands in for the stand-in's
/// (``DaemonStore/adoptMovedTab(_:for:from:landed:)``): the move's apply shows the daemon's pane in the stand-in's place,
/// and `handOver` gives the stand-in's page to the daemon's tab inside that apply, before any view sees the swap. A failure
/// removes the stand-in.
public struct BrowserSplitCommand: Sendable {
    /// The pane the split is beside.
    public let pane: PaneID
    /// Right or down.
    public let direction: SplitDirection
    /// The address the tab opens.
    public let url: String
    /// Its engine tag (`cef`, `webkit`).
    public let engine: String
    /// Its browser profile id; nil is `default`.
    public let profile: String?

    /// Whether `daemon` takes the stand-in: this Mac's daemon, whose tab moves echo their transaction (the move's apply
    /// settles the split). The caller adds its own conditions (a run that may change the view, no incognito window).
    @MainActor public static func offersStandIn(on daemon: DaemonService) -> Bool {
        daemon.isLocal && daemon.supports(DaemonCapability.tabDrag.rawValue)
    }

    public init(pane: PaneID, direction: SplitDirection, url: String, engine: String, profile: String?) {
        self.pane = pane
        self.direction = direction
        self.url = url
        self.engine = engine
        self.profile = profile
    }

    /// The stand-in, and the work that makes and moves the daemon's tab.
    public struct Pending {
        /// The stand-in tab's id (`TabModel.id`), shown in the new pane when ``BrowserSplitCommand/intendNow(on:standIn:create:)``
        /// returns; nil without a stand-in.
        public let tab: String?
        /// Runs the create and the move; returns the daemon's tab. `made` gets that tab as soon as it exists (before
        /// the move); `handOver` runs inside the apply where its pane takes the stand-in's place. Throws the create's
        /// or the move's error (the stand-in is gone then), or ``PaneSplitCancelled``.
        public let send: @MainActor (_ made: @escaping @MainActor (SurfaceID) -> Void,
                                     _ handOver: @escaping @MainActor (SurfaceID) -> Void) async throws -> SurfaceID
    }

    /// Shows the split with its stand-in now when `standIn` (the store's intent log), before any await. `create` sends
    /// `new-frontend-browser-tab`, unselected, in the pane it is given: the source, or for a source that is itself a
    /// stand-in (a second press before the first split landed) the daemon's pane that took it over
    /// (``DaemonStore/daemonTarget(_:)``). A close of the stand-in first cancels the split: the made tab closes and the
    /// work throws ``PaneSplitCancelled``.
    @MainActor
    public func intendNow(on daemon: DaemonService, standIn: Bool, create: @escaping @MainActor (PaneModel) async throws -> SurfaceID) -> Pending {
        let tab = ProvisionalTab(), transaction = ClientTransactionID.generate(), store = daemon.store
        let provisional = standIn ? ProvisionalPane(holding: tab.browser(url: url, engine: engine, profile: profile)) : nil
        if let provisional { store.intend(.splitPane(pane: pane, direction: direction, ratio: 0.5, provisional: provisional), transaction: transaction) }
        let target = pane, edge: PaneEdge = direction == .right ? .right : .bottom
        // The move's events echo the split's transaction, so they settle it in the apply that shows the daemon's pane.
        let echo = daemon.supports(DaemonCapability.tabDrag.rawValue) ? transaction : nil
        // The split leaves the log once the store applied what came before the reply (a cancelled one once its close committed).
        let settle: @MainActor () async -> Void = {
            guard provisional != nil else { return }
            if let sequence = await daemon.connection?.eventSequence() {
                await store.applied(through: sequence)
                store.noteSettled(transaction, at: sequence)
            } else {
                store.noteSettledAtNextSnapshot(transaction)
            }
        }
        return Pending(tab: provisional == nil ? nil : tab.id) { made, handOver in
            var created: SurfaceID?, from: PaneID?
            do {
                let source = try await store.daemonTarget(target)
                guard let model = store.pane(source) else { throw PendingPaneNotCreated() }
                from = source
                let surface = try await create(model)
                created = surface
                made(surface)
                guard let provisional else {
                    try await daemon.perform("split-browser") { connection in
                        _ = try await connection.moveTabToSplit(surface, pane: source, edge: edge, transaction: echo)
                    }
                    return surface
                }
                store.adoptMovedTab(surface, for: provisional, from: source, landed: handOver)
                // A cancelled split's close takes this tab (``CancelledCreation``): nothing moves, focuses or reports it.
                store.creations.noteReply(transaction, surface: surface)
                guard !store.creations.wasCancelled(transaction) else {
                    await settle()
                    throw PaneSplitCancelled()
                }
                try await daemon.perform("split-browser") { connection in
                    _ = try await connection.moveTabToSplit(surface, pane: source, edge: edge, transaction: echo)
                }
                await settle()
                if store.creations.wasCancelled(transaction) { throw PaneSplitCancelled() }
                return surface
            } catch let cancelled as PaneSplitCancelled {
                throw cancelled
            } catch {
                // Closed during the create or the move: the cancel's close takes the tab, as above.
                if provisional != nil, store.creations.wasCancelled(transaction) {
                    if let created { store.creations.noteReply(transaction, surface: created) }
                    await settle()
                    throw PaneSplitCancelled()
                }
                // A lost reply of a move that happened: the tab left its pane, so the split stands.
                if let created, let now = store.pane(containing: created)?.handle, now != from {
                    await settle()
                    return created
                }
                store.rejectIntent(transaction)
                // A tab that did not move is still where it was made: the caller may show it there.
                let left = created.flatMap { surface in store.pane(containing: surface)?.handle == from ? surface : nil }
                throw BrowserSplitFailed(reason: error, left: left)
            }
        }
    }
}

/// A Split Browser whose create or move failed. `left`: the made tab, when it is still in the pane it was made in.
public struct BrowserSplitFailed: Error, CustomStringConvertible {
    /// The create's or the move's error.
    public let reason: any Error
    /// The made tab that did not move, while its pane still holds it.
    public let left: SurfaceID?

    public var description: String { String(describing: reason) }
}
