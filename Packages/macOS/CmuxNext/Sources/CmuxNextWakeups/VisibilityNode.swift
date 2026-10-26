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
/// workspace.deferUntilVisible(key: "appearance") { [weak view] in view?.applyAppearance() }
/// workspace.set(.visible) // token is notified once, then the appearance body runs
/// ```
///
/// Subscribers are told only when ``effective`` flips, after the whole subtree has its new state,
/// parents before children. Hold the ``VisibilitySubscription``: releasing it ends the
/// subscription and releases its closure.
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

    /// Whether ``effective`` is ``Visibility/visible``. O(1): the state is kept, never walked.
    public var isVisible: Bool { effective == .visible }

    /// How many times a propagation recomputed this node (tests prove a flip visits only what can change).
    package private(set) var visits = 0

    private let isRoot: Bool
    private let uptime: Uptime
    /// Children whose own state is visible or occluded: the ones a parent flip can change.
    private var shownChildren: [ObjectIdentifier: WeakNode] = [:]
    /// Children whose own state is hidden: always hidden, never visited by a parent flip.
    private var hiddenChildren: [ObjectIdentifier: WeakNode] = [:]
    /// The entry count at which ``insert(_:)`` drops the entries of released children, doubled
    /// after each pass, so dropping costs O(1) amortized per insert.
    private var compactAt = 16
    private var subscriptions: [WeakSubscription] = []
    /// Told when media starts or stops, or a capture vote begins or ends (``subscribeExemption(owner:_:)``).
    private var exemptionSubscriptions: [WeakSubscription] = []
    /// The value subscribers were last told, so a flip and its undo inside one pass tell nobody.
    private var notified: Visibility
    /// Counts changes of ``notified``: a delivery stops when a subscriber's change started a newer one.
    private var notifyGeneration = 0
    private var deferred: [(key: AnyHashable, work: @MainActor () -> Void)] = []
    private var mediaPlaying = false
    private var mediaStoppedAt: Duration?
    /// The task queues made on this node (``queue(_:owner:on:)``), told of every flip and freeze.
    private var queues: [WeakQueue] = []

    /// Whether ``freeze()`` stopped this node's task queues.
    public private(set) var isFrozen = false

    /// Whether a capture vote that does not stay hidden holds this node: its hidden work runs as if it were
    /// seen (a screenshot, a screencast, screen share). Task 211's `captureVote(reason:stayHidden:)` drives it.
    public private(set) var isCaptured = false

    /// Makes a root node (the app, or a window when the app has no node yet).
    ///
    /// - Parameters:
    ///   - name: The name diagnostics show.
    ///   - own: The starting state.
    ///   - uptime: The clock for ``hiddenSince`` and ``mediaActiveWithin(_:)``.
    public init(root name: String, own: Visibility, uptime: @escaping Uptime = VisibilityNode.systemUptime) {
        self.name = name
        self.own = own
        self.effective = own
        self.notified = own
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
        self.isRoot = false
        self.uptime = parent.uptime
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
        var flipped: [VisibilityNode] = []
        recompute(into: &flipped)
        Self.deliver(flipped)
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
        var flipped: [VisibilityNode] = []
        recompute(into: &flipped)
        Self.deliver(flipped)
    }

    /// Takes this child out of the tree: it and its subtree become hidden.
    public func detach() {
        guard let parent else { return }
        parent.remove(child: ObjectIdentifier(self))
        self.parent = nil
        var flipped: [VisibilityNode] = []
        recompute(into: &flipped)
        Self.deliver(flipped)
    }

    // MARK: Media

    /// Records that this node starts or stops playing audio or video.
    public func setMediaActive(_ active: Bool) {
        guard active != mediaPlaying else { return }
        mediaPlaying = active
        if !active { mediaStoppedAt = uptime() }
        notifyExemption()
    }

    /// Records that a capture vote that does not stay hidden starts or stops holding this node (``isCaptured``).
    public func setCaptured(_ captured: Bool) {
        guard captured != isCaptured else { return }
        isCaptured = captured
        notifyExemption()
    }

    /// Calls `onChange` each time media starts or stops on this node or ``isCaptured`` changes: the inputs of
    /// the hidden-work exemptions, so a pending throttled deadline is placed again at once (Blink's
    /// `PageSchedulerImpl::AudioStateChanged` updates the policy of its throttled queues the same way). Hold the
    /// returned token as a ``subscribe(owner:_:)`` one.
    public func subscribeExemption(owner: String, _ onChange: @escaping @MainActor () -> Void) -> VisibilitySubscription {
        let subscription = VisibilitySubscription(owner: owner, node: self) { _ in onChange() }
        exemptionSubscriptions.removeAll { $0.subscription == nil }
        exemptionSubscriptions.append(WeakSubscription(subscription: subscription))
        return subscription
    }

    private func notifyExemption() {
        exemptionSubscriptions.removeAll { $0.subscription == nil }
        let value = effective
        for subscription in exemptionSubscriptions.compactMap(\.subscription) where subscription.isActive {
            subscription.onFlip(value)
        }
    }

    /// Whether this node plays media now or stopped less than `window` ago. Hidden-work rules exempt
    /// such a node, as Blink's `kRecentAudioDelay` (30 s) keeps a page that played audio from
    /// being throttled or frozen.
    public func mediaActiveWithin(_ window: Duration) -> Bool {
        if mediaPlaying { return true }
        guard let mediaStoppedAt else { return false }
        return uptime() - mediaStoppedAt < window
    }

    // MARK: Task queues

    /// A queue of `workClass` tasks that runs by this node's state (``MainTaskQueue``): held while
    /// the node is not visible (background at hidden wakes), stopped while it is frozen, dropped
    /// with the queue. Work for a hideable owner goes through its node's queue; a plain
    /// ``MainWorkScheduler/post(_:owner:file:line:_:)`` from such an owner says why with `// node-free:`.
    ///
    /// - Parameters:
    ///   - workClass: The class its tasks run in.
    ///   - owner: Its tasks' owner on the board.
    ///   - work: The app's one main-thread scheduler.
    public func queue(_ workClass: BudgetedWorkClass, owner: String, on work: MainWorkScheduler) -> MainTaskQueue {
        let queue = MainTaskQueue(node: self, workClass: workClass, owner: owner, on: work)
        queues.removeAll { $0.queue == nil }
        queues.append(WeakQueue(queue: queue))
        return queue
    }

    /// Stops this node's task queues: none of their tasks runs, visible or not, until
    /// ``unfreeze()`` (Blink's `PageSchedulerImpl::SetPageFrozen`). Child nodes are not frozen.
    public func freeze() {
        guard !isFrozen else { return }
        isFrozen = true
        notifyQueues()
    }

    /// Lets this node's task queues run again by its visibility.
    public func unfreeze() {
        guard isFrozen else { return }
        isFrozen = false
        notifyQueues()
    }

    private func notifyQueues() {
        for queue in queues.compactMap(\.queue) { queue.nodeDidChange() }
    }

    // MARK: Subscribers and deferred work

    /// Calls `onFlip` with the new effective state each time it flips, until the returned token is
    /// released or cancelled. It is not called for the current state.
    ///
    /// - Parameters:
    ///   - owner: The subscriber's name for diagnostics.
    ///   - onFlip: Runs on the main actor after the whole flip has propagated.
    public func subscribe(owner: String, _ onFlip: @escaping @MainActor (Visibility) -> Void) -> VisibilitySubscription {
        let subscription = VisibilitySubscription(owner: owner, node: self, onFlip: onFlip)
        subscriptions.removeAll { $0.subscription == nil }
        subscriptions.append(WeakSubscription(subscription: subscription))
        return subscription
    }

    /// Runs `work` now when this node is visible; otherwise once, when it next becomes visible.
    /// A later call with the same `key` replaces pending work, so a hidden node runs each key once.
    ///
    /// The node holds `work` until it runs: capture the node and its owner weakly.
    public func deferUntilVisible(key: some Hashable, _ work: @escaping @MainActor () -> Void) {
        if isVisible { work(); return }
        let key = AnyHashable(key)
        if let index = deferred.firstIndex(where: { $0.key == key }) {
            deferred[index].work = work
        } else {
            deferred.append((key: key, work: work))
        }
    }

    /// Drops the pending work for `key`, if any.
    public func cancelDeferred(key: some Hashable) {
        let key = AnyHashable(key)
        deferred.removeAll { $0.key == key }
    }

    /// The number of keys waiting for this node to become visible.
    public var deferredCount: Int { deferred.count }

    /// The live subscriptions to this node's flips and to its exemption changes (tests).
    package var subscriberCounts: (flips: Int, exemptions: Int) {
        (subscriptions.count(where: { $0.subscription?.isActive == true }),
         exemptionSubscriptions.count(where: { $0.subscription?.isActive == true }))
    }

    func remove(_ subscription: VisibilitySubscription) {
        subscriptions.removeAll { $0.subscription == nil || $0.subscription === subscription }
        exemptionSubscriptions.removeAll { $0.subscription == nil || $0.subscription === subscription }
    }

    // MARK: Propagation

    private var parentCap: Visibility {
        if isRoot { return .visible }
        return parent?.effective ?? .hidden
    }

    private func recompute(into flipped: inout [VisibilityNode]) {
        visits += 1
        let next = min(own, parentCap)
        guard next != effective else { return }
        if next == .visible {
            hiddenSince = nil
        } else if effective == .visible {
            hiddenSince = uptime()
        }
        if next != .hidden { hiddenStateSince = nil } else if effective != .hidden { hiddenStateSince = uptime() }
        effective = next
        flipped.append(self)
        for child in liveShownChildren() { child.recompute(into: &flipped) }
    }

    /// Notifies each flipped node in propagation order (parents first). A subscriber may change
    /// visibility again; then the nested pass tells everyone the newer state and this pass stops
    /// telling the older one.
    private static func deliver(_ flipped: [VisibilityNode]) {
        for node in flipped { node.deliverFlip() }
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
        if value == .visible { runDeferred() }
    }

    private func runDeferred() {
        while isVisible, !deferred.isEmpty {
            deferred.removeFirst().work()
        }
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

    private struct WeakSubscription {
        weak var subscription: VisibilitySubscription?
    }

    private struct WeakQueue {
        weak var queue: MainTaskQueue?
    }
}

/// A subscription to a ``VisibilityNode``'s flips. The node holds it weakly: releasing the token
/// ends the subscription and releases its closure. ``cancel()`` ends it early.
@MainActor public final class VisibilitySubscription {
    /// The subscriber's name for diagnostics.
    public let owner: String
    let onFlip: @MainActor (Visibility) -> Void
    private weak var node: VisibilityNode?

    init(owner: String, node: VisibilityNode, onFlip: @escaping @MainActor (Visibility) -> Void) {
        self.owner = owner
        self.node = node
        self.onFlip = onFlip
    }

    /// Whether the subscription has not been cancelled.
    var isActive: Bool { node != nil }

    /// Ends the subscription now.
    public func cancel() {
        node?.remove(self)
        node = nil
    }
}
