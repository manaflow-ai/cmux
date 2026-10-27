import Darwin

/// One thing a person can or cannot see (app, window, workspace, pane, tab, sidebar row) in the
/// visibility tree that decides what main-thread work runs (plans/cmux-next/chrome-parity/
/// p06-scheduler.md, section B). Chromium keeps the same state per WebContents
/// (`content/public/browser/visibility.h`, `WebContentsImpl::UpdateWebContentsVisibility`).
///
/// Each node has its own state, set by its owner, and an ``effective`` state:
/// `min(own, parent.effective)`. A root has no parent and its effective state is its own; a
/// detached child is hidden.
///
/// The tree does not keep nodes alive: the parent is weak, and a parent holds its children weakly
/// in two sets by their own state. Own-hidden children are always hidden, so a parent's flip
/// visits only the other set: 1000 hidden rows under a flipping window cost nothing. When the
/// thing a node stands for closes, its owner calls ``detach()`` (as a ``FrameClient`` owner
/// deactivates), so its subtree hears the flip to hidden; the node has no deinit work.
///
/// ```swift
/// let window = VisibilityNode(root: "window", own: .visible)
/// let workspace = VisibilityNode("workspace", own: .hidden, parent: window)
/// let token = workspace.subscribe(owner: "Sidebar.rows") { visibility in rows.apply(visibility) }
/// workspace.deferAppearance(owner: "Strip") { [weak view] in view?.applyAppearance() }
/// workspace.set(.visible) // token is notified once, then the appearance body runs
/// ```
///
/// A view hidden in AppKit forwards it and nothing else (recipe R-hide): `viewDidHide` calls
/// `node.set(.hidden)`, `viewDidUnhide` calls `node.set(.visible)`, and work a hidden view skips waits in
/// ``deferUntilVisible(key:_:)`` under a key, so a show runs each kind of work once.
///
/// Subscribers are told only when ``effective`` flips, after the whole subtree has its new state,
/// parents before children. Hold the ``VisibilitySubscription``: releasing it ends the
/// subscription and releases its closure.
///
/// A capture of something nobody sees (an agent's screenshot or screencast of a hidden tab, a
/// shared screen) takes a vote with ``captureVote(reason:stayHidden:)``, as Chromium's
/// `WebContents::IncrementCapturerCount(size, stay_hidden, stay_awake)`
/// (content/public/browser/web_contents.h) keeps a hidden page rendering. While a vote holds a node,
/// the node and its own-shown subtree render (``wantsFrames``): frame clients tick, view
/// observations apply, the node's task queues run and its deferred view work
/// (``deferUntilVisible(key:_:)``) runs. A `stayHidden` vote leaves ``effective``,
/// page visibility and the hidden timer alignment as they are; any other vote makes the node
/// ``Visibility/visible``.
///
/// On show, the observers under a node re-read by its ``resolvedShowOrder``: in the show turn (on
/// screen in the focused pane), or after the show pass as one userBlocking task each, in viewport
/// rank order. A ``warmVote(reason:)`` (a hovered tab, the Ctrl-Tab target, a neighbor tab) keeps
/// the values of a hidden node's observers fresh in idle time, so its show reads nothing.
@MainActor public final class VisibilityNode {
    /// Monotonic time since an arbitrary origin (`CLOCK_UPTIME_RAW` in the app, as Chromium's
    /// `base::TimeTicks` on the Mac). Tests inject a fake.
    public typealias Uptime = @MainActor @Sendable () -> Duration

    /// The system uptime clock.
    public static let systemUptime: Uptime = { .nanoseconds(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) }

    /// The name diagnostics show (`window`, `workspace:<id>`, `tab:<id>`).
    public let name: String
    /// The state the owner set with ``set(_:)``.
    public private(set) var own: Visibility
    /// `min(own, parent.effective)`; ``own`` for a root; ``Visibility/hidden`` for a child without a parent.
    public private(set) var effective: Visibility
    /// The node this one is under; `nil` for a root or a detached child.
    public private(set) weak var parent: VisibilityNode?
    /// When ``effective`` last left ``Visibility/visible`` (``uptime`` time); `nil` while visible.
    /// Occluded counts as not visible, as Blink's page visibility treats an occluded WebContents.
    /// Hidden-work rules such as the 5-minute timer alignment read it.
    public private(set) var hiddenSince: Duration?
    /// When ``effective`` last became ``Visibility/hidden``; `nil` while visible or occluded (Chrome `WasHidden`).
    public private(set) var hiddenStateSince: Duration?
    /// Whether a capture vote holds this node, or holds an ancestor and every node between them and
    /// this one is not own-hidden (an unselected tab of a captured pane is not in the picture).
    /// Chromium's `WebContentsImpl::IsBeingCaptured()`.
    public private(set) var isCaptured = false

    /// Whether ``effective`` is ``Visibility/visible``. O(1): the state is kept, never walked.
    public var isVisible: Bool { effective == .visible }

    /// Whether this node renders: it is ``Visibility/visible``, or a capture vote holds it
    /// (``isCaptured``: a screenshot, a screencast or screen share sees it while it is hidden).
    /// Frame clients, view observations, the node's task queues and its deferred work follow it.
    public var wantsFrames: Bool { isVisible || isCaptured }

    /// How many times a propagation recomputed this node (tests prove a flip visits only what can change).
    package private(set) var visits = 0

    private let isRoot: Bool
    let uptime: Uptime
    /// The counts a root was made with (``workCounts``); nil on a child.
    let rootWorkCounts: VisibilityWorkCounts?
    /// Children whose own state is visible or occluded: the ones a parent flip can change.
    private var shownChildren: [ObjectIdentifier: WeakNode] = [:]
    /// Children whose own state is hidden: always hidden, never visited by a parent flip.
    private var hiddenChildren: [ObjectIdentifier: WeakNode] = [:]
    /// The entry count at which ``insert(_:)`` drops the entries of released children, doubled
    /// after each pass, so dropping costs O(1) amortized per insert.
    private var compactAt = 16
    var subscriptions: [WeakSubscription] = []
    /// Told when media starts or stops, or ``isCaptured`` changes (``subscribeExemption(owner:_:)``).
    var exemptionSubscriptions: [WeakSubscription] = []
    /// Told when ``wantsFrames`` changes (``subscribeRendering(owner:_:)``).
    var renderingSubscriptions: [WeakSubscription] = []
    /// The value subscribers were last told, so a flip and its undo inside one pass tell nobody.
    private var notified: Visibility
    /// ``isCaptured`` and ``wantsFrames`` as their subscribers were last told.
    private var notifiedCaptured = false
    private var notifiedRendering: Bool
    /// Counts changes of ``notifiedRendering``, as ``notifyGeneration`` does for flips.
    private var renderingGeneration = 0
    /// The capture votes on this node, in the order they were taken.
    var votes: [CaptureRecord] = []
    var nextVoteID: UInt64 = 0
    /// Counts changes of ``notified``: a delivery stops when a subscriber's change started a newer one.
    private var notifyGeneration = 0
    /// Work waiting for the node to reach `from` (``deferUntilVisible(key:_:)``, ``deferUntilShown(key:_:)``).
    var deferred: [(key: AnyHashable, from: Visibility, work: @MainActor () -> Void)] = []
    var mediaPlaying = false
    var mediaStoppedAt: Duration?
    /// The task queues made on this node (``queue(_:owner:on:)``), told of every flip and freeze.
    var queues: [WeakQueue] = []
    /// The warm votes on this node (``warmVote(reason:)``), oldest first.
    var warmVotes: [WarmRecord] = []
    /// Told when ``isWarm`` changes (``subscribeWarm(owner:_:)``).
    var warmSubscriptions: [WeakSubscription] = []
    private var notifiedWarm: Bool
    /// The after-show posts of the pass this node started and is delivering now (``postAfterShow(rank:_:)``).
    var afterShow: [AfterShowPost]?

    /// Whether ``freeze()`` stopped this node's task queues.
    public internal(set) var isFrozen = false
    /// Whether a warm vote holds this node, or holds an ancestor with no own-hidden node between them
    /// (``warmVote(reason:)``): its observers keep their values fresh in idle time while it is hidden.
    public private(set) var isWarm = false
    /// When observers under this node re-read on show; nil follows the parent (``resolvedShowOrder``).
    public var showOrder: ShowOrder?

    /// Makes a root node (the app, or a window when the app has no node yet).
    ///
    /// - Parameters:
    ///   - name: The name diagnostics show.
    ///   - own: The starting state.
    ///   - uptime: The clock for ``hiddenSince`` and ``mediaActiveWithin(_:)``.
    ///   - workCounts: Where the tree's nodes count their work (``workCounts``); nil counts nothing.
    public init(root name: String, own: Visibility, uptime: @escaping Uptime = VisibilityNode.systemUptime,
                workCounts: VisibilityWorkCounts? = nil) {
        self.name = name
        self.rootWorkCounts = workCounts
        self.own = own
        self.effective = own
        self.notified = own
        self.notifiedRendering = own == .visible
        self.notifiedWarm = false
        self.isRoot = true
        self.uptime = uptime
        self.hiddenSince = own == .visible ? nil : uptime()
        self.hiddenStateSince = own == .hidden ? uptime() : nil
    }

    /// Makes a child of `parent`. It uses the parent's clock.
    ///
    /// - Parameters:
    ///   - name: The name diagnostics show.
    ///   - own: The starting state; `visible` makes the node follow its parent.
    ///   - parent: The node it is under.
    public init(_ name: String, own: Visibility = .visible, parent: VisibilityNode) {
        let effective = min(own, parent.effective)
        self.name = name
        self.own = own
        self.effective = effective
        self.notified = effective
        let captured = own != .hidden && parent.isCaptured
        self.isCaptured = captured
        self.notifiedCaptured = captured
        self.notifiedRendering = effective == .visible || captured
        let warm = own != .hidden && parent.isWarm
        self.isWarm = warm
        self.notifiedWarm = warm
        self.isRoot = false
        self.uptime = parent.uptime
        self.rootWorkCounts = nil
        self.hiddenSince = effective == .visible ? nil : parent.uptime()
        self.hiddenStateSince = effective == .hidden ? parent.uptime() : nil
        self.parent = parent
        parent.insert(self)
    }

    // MARK: State

    /// Sets the owner's state and propagates the change to the subtree whose effective state
    /// changes, then notifies the flipped nodes' subscribers. Setting the current state does nothing.
    public func set(_ visibility: Visibility) { // perf-hot: 0.1ms workspace-switch (O(changed subtree) per flip)
        guard visibility != own else { return }
        let wasHidden = own == .hidden
        own = visibility
        if let parent, wasHidden != (visibility == .hidden) { parent.insert(self) }
        repropagate()
    }

    /// Why ``attach(to:)`` refused a move; the tree is unchanged.
    public enum MoveError: Error, Equatable {
        /// The node was made with ``init(root:own:uptime:)``.
        case isRoot
        /// The new parent is this node or below it: the move would make a cycle.
        case wouldCycle
    }

    /// Moves this child under `newParent` and propagates its new effective state.
    ///
    /// - Throws: ``MoveError`` for a root, or a parent in this node's own subtree.
    public func attach(to newParent: VisibilityNode) throws(MoveError) {
        guard !isRoot else { throw .isRoot }
        guard !newParent.isInSubtree(of: self) else { throw .wouldCycle }
        guard newParent !== parent else { return }
        parent?.remove(child: ObjectIdentifier(self))
        parent = newParent
        newParent.insert(self)
        repropagate()
    }

    /// Takes this child out of the tree: it and its subtree become hidden.
    public func detach() {
        guard let parent else { return }
        parent.remove(child: ObjectIdentifier(self))
        self.parent = nil
        repropagate()
    }

    /// Recomputes this node and the subtree a change can reach, then notifies what changed
    /// (``set(_:)``, a move, a capture vote).
    func repropagate() {
        var changed: [VisibilityNode] = []
        recompute(into: &changed)
        let outer = afterShow
        afterShow = []
        Self.deliver(changed)
        let posts = afterShow ?? []
        afterShow = outer
        Self.runAfterShow(posts)
    }

    // MARK: Propagation

    private var parentCap: Visibility {
        if isRoot { return .visible }
        return parent?.effective ?? .hidden
    }

    /// A parent's capture reaches only a child that is not own-hidden, so the own-hidden children a
    /// parent's change never visits are captured by their own votes alone.
    private var parentCaptured: Bool {
        !isRoot && own != .hidden && parent?.isCaptured == true
    }

    /// A parent's warm vote reaches the same children its capture would.
    private var parentWarm: Bool {
        !isRoot && own != .hidden && parent?.isWarm == true
    }

    private func recompute(into changed: inout [VisibilityNode]) {
        visits += 1
        let next = votes.contains(where: { !$0.stayHidden }) ? Visibility.visible : min(own, parentCap)
        let captured = !votes.isEmpty || parentCaptured
        let warm = !warmVotes.isEmpty || parentWarm
        guard next != effective || captured != isCaptured || warm != isWarm else { return }
        if next == .visible {
            hiddenSince = nil
        } else if effective == .visible {
            hiddenSince = uptime()
        }
        if next != .hidden { hiddenStateSince = nil } else if effective != .hidden { hiddenStateSince = uptime() }
        effective = next
        isCaptured = captured
        isWarm = warm
        changed.append(self)
        for child in liveShownChildren() { child.recompute(into: &changed) }
    }

    /// Notifies each changed node in propagation order (parents first). A subscriber may change
    /// visibility again; then the nested pass tells everyone the newer state and this pass stops
    /// telling the older one.
    private static func deliver(_ changed: [VisibilityNode]) {
        for node in changed {
            node.deliverFlip()
            node.deliverRendering()
            node.deliverWarm()
        }
    }

    /// Tells the rendering subscribers that ``wantsFrames`` changed, then the exemption subscribers
    /// that ``isCaptured`` did, once per change however many votes come and go.
    private func deliverRendering() {
        let rendering = wantsFrames
        if rendering != notifiedRendering {
            notifiedRendering = rendering
            renderingGeneration += 1
            let generation = renderingGeneration
            notifyQueues()
            renderingSubscriptions.removeAll { $0.subscription == nil }
            for subscription in renderingSubscriptions.compactMap(\.subscription) where subscription.isActive {
                guard renderingGeneration == generation else { return }
                subscription.onFlip(effective)
            }
            guard renderingGeneration == generation else { return }
        }
        runDeferredIfReached()
        guard isCaptured != notifiedCaptured else { return }
        notifiedCaptured = isCaptured
        notifyExemption()
    }

    /// Tells the warm subscribers that ``isWarm`` changed, once per change.
    private func deliverWarm() {
        guard isWarm != notifiedWarm else { return }
        notifiedWarm = isWarm
        warmSubscriptions.removeAll { $0.subscription == nil }
        let value = effective
        for subscription in warmSubscriptions.compactMap(\.subscription) where subscription.isActive {
            subscription.onFlip(value)
        }
    }

    private func deliverFlip() {
        let value = effective
        guard value != notified else { return }
        notified = value
        notifyGeneration += 1
        let generation = notifyGeneration
        // Queues only post on a flip, never run inline, so they hear it first.
        notifyQueues()
        subscriptions.removeAll { $0.subscription == nil }
        for subscription in subscriptions.compactMap(\.subscription) where subscription.isActive {
            guard notifyGeneration == generation else { return }
            subscription.onFlip(value)
        }
        guard notifyGeneration == generation else { return }
        runDeferredIfReached()
    }

    // MARK: Children

    private func insert(_ child: VisibilityNode) {
        if shownChildren.count + hiddenChildren.count >= compactAt {
            shownChildren = shownChildren.filter { $0.value.node != nil }
            hiddenChildren = hiddenChildren.filter { $0.value.node != nil }
            compactAt = max(16, 2 * (shownChildren.count + hiddenChildren.count))
        }
        let id = ObjectIdentifier(child)
        if child.own == .hidden {
            shownChildren[id] = nil
            hiddenChildren[id] = WeakNode(node: child)
        } else {
            hiddenChildren[id] = nil
            shownChildren[id] = WeakNode(node: child)
        }
    }

    private func remove(child id: ObjectIdentifier) {
        shownChildren[id] = nil
        hiddenChildren[id] = nil
    }

    private func liveShownChildren() -> [VisibilityNode] {
        var live: [VisibilityNode] = []
        live.reserveCapacity(shownChildren.count)
        var dead: [ObjectIdentifier] = []
        for (id, entry) in shownChildren {
            if let node = entry.node { live.append(node) } else { dead.append(id) }
        }
        for id in dead { shownChildren[id] = nil }
        return live
    }

    private func isInSubtree(of ancestor: VisibilityNode) -> Bool {
        var node: VisibilityNode? = self
        while let current = node {
            if current === ancestor { return true }
            node = current.parent
        }
        return false
    }

    /// The number of live children in each set (diagnostics and tests).
    package var childCounts: (shown: Int, hidden: Int) {
        (shownChildren.values.count(where: { $0.node != nil }), hiddenChildren.values.count(where: { $0.node != nil }))
    }

    /// The number of child entries kept, released children's included (tests prove they are dropped).
    package var childEntryCount: Int { shownChildren.count + hiddenChildren.count }

    private struct WeakNode {
        weak var node: VisibilityNode?
    }

    struct WeakSubscription {
        weak var subscription: VisibilitySubscription?
    }
}
