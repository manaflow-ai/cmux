/// A node's flip subscribers and the work it defers until it is visible or shown
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, section B).
extension VisibilityNode {
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

    /// Runs `work` now when this node renders (``wantsFrames``: it is visible, or a capture vote
    /// holds it); otherwise once, when it next renders. A later call with the same `key` replaces
    /// pending work, so a hidden node runs each key once. The work is view work (the R-appear and
    /// R-hide recipes), and a capture draws the views, so it runs for a capture as a view
    /// observation applies for one.
    ///
    /// The node holds `work` until it runs: capture the node and its owner weakly.
    public func deferUntilVisible(key: some Hashable, _ work: @escaping @MainActor () -> Void) {
        hold(work, until: .visible, key: AnyHashable(key))
    }

    /// Runs `work` now when this node is not hidden (visible or occluded) or renders (``wantsFrames``);
    /// otherwise once, when it next is. For layout work: an occluded node keeps its layout ready
    /// (``Visibility/occluded``), so its sizes apply while it is covered, and a capture draws the views at
    /// their sizes. Keys are shared with ``deferUntilVisible(key:_:)``: a later call with the same `key`
    /// replaces pending work.
    ///
    /// The node holds `work` until it runs: capture the node and its owner weakly.
    public func deferUntilShown(key: some Hashable, _ work: @escaping @MainActor () -> Void) {
        hold(work, until: .occluded, key: AnyHashable(key))
    }

    private func hold(_ work: @escaping @MainActor () -> Void, until from: Visibility, key: AnyHashable) {
        if reaches(from) { work(); return }
        if let index = deferred.firstIndex(where: { $0.key == key }) {
            deferred[index] = (key: key, from: from, work: work)
        } else {
            deferred.append((key: key, from: from, work: work))
        }
    }

    /// Re-applies `owner`'s appearance (recipe R-appear): now when this node is visible, else once when
    /// it next shows, however many theme, contrast or scale changes came meanwhile. A
    /// `viewDidChangeEffectiveAppearance` body that does more than set layer colors (measures text,
    /// rebuilds layers, lays out) goes through it, so a theme flip costs what is on screen; a hidden
    /// `RenderWidgetHostImpl` likewise sends its visual properties once, in `WasShown`
    /// (content/browser/renderer_host/render_widget_host_impl.cc). Each run counts in
    /// ``VisibilityWorkCounts/appearanceApplies``.
    ///
    /// - Parameters:
    ///   - owner: The view's name; one pending body per owner on this node.
    ///   - apply: The appearance body. The node holds it until it runs: capture the view weakly.
    public func deferAppearance(owner: String, _ apply: @escaping @MainActor () -> Void) {
        deferUntilVisible(key: AppearanceKey(owner: owner)) { [weak self] in
            self?.workCounts?.appearanceApplies &+= 1
            apply()
        }
    }

    /// Where this node counts its work: its root's counts (``init(root:own:uptime:workCounts:)``), read
    /// when the work runs, so a node moved to another tree counts there. Nil while detached.
    public var workCounts: VisibilityWorkCounts? {
        var node = self
        while let parent = node.parent { node = parent }
        return node.rootWorkCounts
    }

    private struct AppearanceKey: Hashable {
        let owner: String
    }

    /// Drops the pending work for `key`, if any.
    public func cancelDeferred(key: some Hashable) {
        let key = AnyHashable(key)
        deferred.removeAll { $0.key == key }
    }

    /// The number of keys waiting for this node to become visible (or, for ``deferUntilShown(key:_:)``, not hidden).
    public var deferredCount: Int { deferred.count }

    /// The live subscriptions to this node's flips, exemption changes and rendering changes (tests).
    package var subscriberCounts: (flips: Int, exemptions: Int, rendering: Int) {
        (subscriptions.count(where: { $0.subscription?.isActive == true }),
         exemptionSubscriptions.count(where: { $0.subscription?.isActive == true }),
         renderingSubscriptions.count(where: { $0.subscription?.isActive == true }))
    }

    func remove(_ subscription: VisibilitySubscription) {
        subscriptions.removeAll { $0.subscription == nil || $0.subscription === subscription }
        exemptionSubscriptions.removeAll { $0.subscription == nil || $0.subscription === subscription }
        renderingSubscriptions.removeAll { $0.subscription == nil || $0.subscription === subscription }
        warmSubscriptions.removeAll { $0.subscription == nil || $0.subscription === subscription }
    }

    /// Whether deferred work waiting for `from` runs now: the node renders (``wantsFrames``: visible, or a
    /// capture vote holds it), or its state is at least `from`.
    func reaches(_ from: Visibility) -> Bool {
        wantsFrames || effective >= from
    }

    /// Runs, in the order they were deferred, the bodies this node's state now reaches (a body that hides it
    /// again leaves the rest for the next time it reaches them: each pick reads the state again). It follows
    /// the node's state now, not whether that changed: a subscriber can defer work while the node is hidden
    /// and show it again inside the same pass.
    func runDeferredIfReached() {
        while let index = deferred.firstIndex(where: { reaches($0.from) }) {
            deferred.remove(at: index).work()
        }
    }
}
