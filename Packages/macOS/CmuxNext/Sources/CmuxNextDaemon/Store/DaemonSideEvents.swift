/// Events that are not part of the tree snapshot (bookmarks, local
/// conversations, capability events this module does not model such as
/// `apps-*`), fanned out in arrival order to the services that own their
/// projections. Each subscriber filters the cases it needs.
@MainActor
public final class DaemonSideEvents {
    private var subscribers: [UInt64: (DaemonEvent) -> Void] = [:]
    private var next: UInt64 = 0

    public init() {}

    /// Adds a subscriber; returns the token that removes it.
    @discardableResult
    public func subscribe(_ handler: @escaping (DaemonEvent) -> Void) -> UInt64 {
        next += 1
        subscribers[next] = handler
        return next
    }

    public func unsubscribe(_ token: UInt64) {
        subscribers[token] = nil
    }

    func deliver(_ event: DaemonEvent) {
        for subscriber in subscribers.values { subscriber(event) }
    }
}
