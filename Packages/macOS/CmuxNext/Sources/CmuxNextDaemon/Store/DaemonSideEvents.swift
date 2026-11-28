/// Events that are not part of the tree snapshot (bookmarks, local
/// conversations, the app supervisor's `apps-*` events), fanned out in arrival order to the services that own their
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

    /// An event of the app supervisor (capability `apps-v1`): `apps-changed`,
    /// `apps-scene`, `apps-provider-request` and the rest. This module does not
    /// model them (`DaemonEvent.unknown`); the apps client reads them.
    public nonisolated static func isAppsEvent(_ name: String) -> Bool { name.hasPrefix("apps-") }

    func deliver(_ event: DaemonEvent) {
        for subscriber in subscribers.values { subscriber(event) }
    }
}
