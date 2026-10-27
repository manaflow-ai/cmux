/// A node's flip subscribers and the work it defers until it is visible
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

    func runDeferred() {
        while isVisible, !deferred.isEmpty {
            deferred.removeFirst().work()
        }
    }
}
