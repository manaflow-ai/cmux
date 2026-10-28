/// The show order and warm votes (plans/cmux-next/chrome-parity/p06-scheduler.md, section B, "Show
/// order"; task 213): what a show costs in its own turn.
///
/// Chrome makes the same split when a tab is shown: `RenderWidgetHostImpl::WasShown`
/// (content/browser/renderer_host/render_widget_host_impl.cc) asks the shown widget for its frame at
/// once, and the rest of the work runs as prioritized tasks in Blink's scheduler queues; the tab a
/// person is about to switch to can be prepared before it is shown, without drawing it.
extension VisibilityNode {
    /// When the observers under a node re-read their values on show.
    public enum ShowOrder: Equatable, Sendable {
        /// In the show turn: what is on screen in the focused pane.
        case inShowTurn
        /// After the show pass, as one userBlocking task per observer: posted in `rank` order (lower
        /// first, viewport order), so they land in the next one or two frames.
        case afterShow(rank: Int)
    }

    /// This node's ``showOrder``, or its nearest ancestor's; ``ShowOrder/inShowTurn`` when none has one.
    public var resolvedShowOrder: ShowOrder {
        var node: VisibilityNode? = self
        while let current = node {
            if let order = current.showOrder { return order }
            node = current.parent
        }
        return .inShowTurn
    }

    // MARK: After-show posts

    /// Calls `post` after the visibility pass delivering now, with that pass's other after-show posts in
    /// `rank` order (posts of one rank in call order); at once when no pass is delivering. A
    /// ``VisibleObservation`` whose node shows posts its userBlocking re-read task through it.
    func postAfterShow(rank: Int, _ post: @escaping @MainActor () -> Void) {
        var node: VisibilityNode? = self
        while let current = node {
            if var posts = current.afterShow {
                current.afterShow = nil
                posts.append(AfterShowPost(rank: rank, order: posts.count, post: post))
                current.afterShow = posts
                return
            }
            node = current.parent
        }
        post()
    }

    static func runAfterShow(_ posts: [AfterShowPost]) {
        guard !posts.isEmpty else { return }
        for item in posts.sorted(by: { ($0.rank, $0.order) < ($1.rank, $1.order) }) { item.post() }
    }

    // MARK: Warm votes

    /// Warms this node for `reason` until ``VisibilityWarmVote/release()``: while it is hidden, the
    /// observers under it re-read in idle time and keep the value without applying it, so a show
    /// applies it with no read. A hovered tab, the Ctrl-Tab target and the neighbor tabs take one.
    /// Votes add up; the first and the last release each change ``isWarm`` once. A warm vote changes
    /// nothing a person sees, and nothing renders for it (a capture vote does that).
    public func warmVote(reason: String) -> VisibilityWarmVote {
        nextVoteID &+= 1
        warmVotes.append(WarmRecord(id: nextVoteID, reason: reason))
        repropagate()
        return VisibilityWarmVote(id: nextVoteID, reason: reason, node: self)
    }

    /// The reasons of the warm votes on this node, oldest first (diagnostics).
    public var warmReasons: [String] { warmVotes.map(\.reason) }

    func releaseWarmVote(_ id: UInt64) {
        guard let index = warmVotes.firstIndex(where: { $0.id == id }) else { return }
        warmVotes.remove(at: index)
        repropagate()
    }

    /// Calls `onChange` with ``isWarm`` each time it changes, not for the current value. Hold the
    /// returned token as a ``subscribe(owner:_:)`` one.
    public func subscribeWarm(owner: String, _ onChange: @escaping @MainActor (Bool) -> Void) -> VisibilitySubscription {
        let subscription = VisibilitySubscription(owner: owner, node: self) { [weak self] _ in onChange(self?.isWarm ?? false) }
        warmSubscriptions.removeAll { $0.subscription == nil }
        warmSubscriptions.append(WeakSubscription(subscription: subscription))
        return subscription
    }
}

/// One post a show pass runs after its delivery (``VisibilityNode/postAfterShow(rank:_:)``).
struct AfterShowPost {
    let rank: Int
    /// Its place among the pass's posts, so equal ranks keep call order.
    let order: Int
    let post: @MainActor () -> Void
}

/// One warm vote on a node, as the node keeps it.
struct WarmRecord {
    let id: UInt64
    let reason: String
}
