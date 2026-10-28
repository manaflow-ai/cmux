import CmuxNextDaemon
public import CmuxNextWakeups

/// What the reporter follows of the store's connection: which connection is up, and its tab list's revision (a
/// tab the app shows may get its surface only when the daemon lists it).
nonisolated struct FrontendVisibilityLink: Sendable, Equatable {
    var epoch: Int
    var tabs: UInt64
}

/// Tells the local daemon which tabs this app shows (`frontend.visibility.set`), so the daemon
/// holds the latest-state events of the others (titles, agent and program status, output, scroll) and sends them
/// once per aligned second, or at once when the tab shows. Chrome's browser process tells each renderer when its
/// page shows or hides (`RenderWidgetHostImpl::WasShown`/`WasHidden`,
/// content/browser/renderer_host/render_widget_host_impl.cc), and the renderer throttles a hidden page's work.
///
/// It follows each tab's node in the visibility tree (``track(_:node:)``): a flip marks the set dirty, and one
/// frame task sends the whole set of shown surfaces, only when it changed, so a workspace switch that flips many
/// tabs sends one line, at most once per frame. Each `.connected` epoch of the store is told afresh (the daemon
/// drops a connection's set with it), and a change of the tab list re-reads the surfaces, since a tab shown before
/// the daemon listed it has none yet. Nodes are held weakly: a node nobody holds is no tab anyone sees.
final class FrontendVisibilityReporter {
    /// Sends one request to the connected daemon; false when it failed.
    typealias Send = @MainActor @Sendable (FrontendVisibilitySetRequest) async -> Bool
    /// Runs work on the next display frame (a ``FrameBatchQueue`` in the app; the test's hand in tests).
    typealias Frame = @MainActor (@escaping @MainActor () -> Void) -> Void

    private weak var store: DaemonStore?
    /// Each followed tab's node and its subscription, by tab key.
    private var tracked: [String: Tracked] = [:]
    /// `tracked` drops the entries of released nodes when it reaches this many.
    private var pruneAt = 64
    /// The keys of tracked tabs whose node is visible: the set is built from these, never from every tab.
    private(set) var shownKeys: Set<String> = []
    /// The connection's epoch while it is connected; nil while it is not.
    private(set) var connection: Int?
    /// What this connection was told; nil until it is told, after a failed send and while there is no connection.
    private(set) var told: [SurfaceID]?
    /// Whether this frame's report is queued (tests).
    private(set) var reportQueued = false
    private let frame: Frame
    private var link: ServiceObservation<FrontendVisibilityLink?>?
    /// The latest set not yet sent (newest one kept), and the one pump off main that sends it.
    private let requests: AsyncStream<FrontendVisibilitySetRequest>.Continuation
    private var pump: Task<Void, Never>?

    /// A reporter whose one report per frame runs on `work`'s frame scheduler.
    ///
    /// - Parameters:
    ///   - store: The local daemon's store: its connection, its capabilities and each tab's surface.
    ///   - work: The app's main-thread scheduler.
    ///   - send: Sends one request (``DaemonService/run(_:_:)`` in the app; a recorder in tests).
    convenience init(store: DaemonStore, on work: MainWorkScheduler, send: @escaping Send) {
        let frames = FrameBatchQueue(owner: "FrontendVisibilityReporter", scheduler: work.frames)
        self.init(store: store, on: work, frame: { frames.enqueue($0) }, send: send)
    }

    /// - Parameters:
    ///   - store: The local daemon's store: its connection, its capabilities and each tab's surface.
    ///   - work: The app's main-thread scheduler, for the connection observation.
    ///   - frame: Runs the one report of a frame.
    ///   - send: Sends one request.
    init(store: DaemonStore, on work: MainWorkScheduler, frame: @escaping Frame, send: @escaping Send) {
        self.store = store
        self.frame = frame
        let (stream, requests) = AsyncStream.makeStream(of: FrontendVisibilitySetRequest.self,
                                                        bufferingPolicy: .bufferingNewest(1))
        self.requests = requests
        // task-owner: this reporter; deinit finishes the stream, which ends the pump
        pump = Task { @concurrent [weak self] in
            for await request in stream {
                if await send(request) { continue }
                await self?.failed(request)
            }
        }
        // `visible`: a tab the person just opened waits for its surface here.
        link = ServiceObservation<FrontendVisibilityLink?>(.visible, owner: "FrontendVisibilityReporter.connection", on: work) {
            [weak store] () -> FrontendVisibilityLink? in
            guard let store, case .connected = store.connectionState else { return nil }
            return FrontendVisibilityLink(epoch: store.connectionEpoch, tabs: store.tabListRevision)
        } apply: { [weak self] link in
            self?.linked(link)
        }
    }

    nonisolated deinit {
        requests.finish()
    }

    /// Follows tab `key`'s node (``TabContentCache``'s, one per tab): its flips decide whether the tab is shown.
    /// Tracking the same node again does nothing; a new node for the key replaces the old one.
    func track(_ key: String, node: VisibilityNode) {
        if let entry = tracked[key], entry.node === node { return }
        let subscription = node.subscribe(owner: "FrontendVisibilityReporter") { [weak self] visibility in
            self?.flipped(key, shown: visibility == .visible)
        }
        tracked[key] = Tracked(node: node, subscription: subscription)
        flipped(key, shown: node.isVisible)
        if tracked.count >= pruneAt { prune() }
    }

    private func flipped(_ key: String, shown: Bool) {
        let changed = shown ? shownKeys.insert(key).inserted : shownKeys.remove(key) != nil
        if changed { setNeedsReport() }
    }

    /// The store's connection changed: a new one is told the set afresh; a new tab list may resolve a surface.
    private func linked(_ link: FrontendVisibilityLink?) {
        guard let link else {
            connection = nil
            told = nil
            return
        }
        if link.epoch != connection {
            connection = link.epoch
            told = nil
        }
        setNeedsReport()
    }

    /// Queues the one report of this frame.
    private func setNeedsReport() {
        guard connection != nil, !reportQueued else { return }
        reportQueued = true
        frame { [weak self] in self?.report() }
    }

    /// Sends the shown surfaces when they changed since this connection was last told.
    func report() {
        reportQueued = false
        guard connection != nil, let store, store.supports(DaemonCapability.frontendVisibility.rawValue) else { return }
        let visible = shownKeys.compactMap { key -> SurfaceID? in
            guard tracked[key]?.node?.isVisible == true else { return nil }
            return store.tab(id: key)?.surface
        }.sorted()
        guard visible != told else { return }
        told = visible
        requests.yield(FrontendVisibilitySetRequest(visible: visible))
    }

    /// A send failed: the daemon may hold an older set, so the next change sends the whole set again. It does not
    /// retry on its own: a daemon that refuses would be asked every frame.
    private func failed(_ request: FrontendVisibilitySetRequest) {
        if told == request.visible { told = nil }
    }

    /// Drops the entries of released nodes.
    private func prune() {
        tracked = tracked.filter { $0.value.node != nil }
        shownKeys.formIntersection(tracked.keys)
        pruneAt = max(64, tracked.count * 2)
    }

    private struct Tracked {
        weak var node: VisibilityNode?
        let subscription: VisibilitySubscription
    }
}

extension DaemonService {
    /// Tells the local daemon which tabs this app shows (``FrontendVisibilityReporter``, feature
    /// `frontendVisibilityScope`). A Cloud machine's daemon is not told. The composition root calls it once, before
    /// the first tab node exists.
    public func reportFrontendVisibility(on work: MainWorkScheduler) {
        guard isLocal, frontendVisibility == nil else { return }
        frontendVisibility = FrontendVisibilityReporter(store: store, on: work) { [weak self] request in
            guard let self else { return false }
            return await run("frontend.visibility.set") { _ = try await $0.request(request) }
        }
    }

    /// Follows tab `key`'s visibility node for the report; nothing while the app does not report.
    public func trackVisibility(ofTab key: String, node: VisibilityNode) {
        frontendVisibility?.track(key, node: node)
    }
}
