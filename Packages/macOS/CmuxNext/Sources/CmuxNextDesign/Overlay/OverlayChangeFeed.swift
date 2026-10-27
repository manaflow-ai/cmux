import CmuxNextCompat

/// Says "what is above a window's content changed" to every subscriber, from the owners' own change points:
/// an overlay presented, dismissed or no longer taking the mouse on a ``WindowOverlayHost`` (dialogs, toasts,
/// popovers, menus), a hover card shown or hidden (``HoverCardCoordinator``), and the App's focus overlays (the
/// palette, sheets), and the dialog center's opens and answers (an app dialog's host has no window). The App's
/// composition root makes one and gives it to those owners; `debug.oracle.wait_for`
/// on the `overlays` facet subscribes, so a wait wakes when a dialog opens instead of timing out. Each subscriber
/// buffers at most one pending signal: it only says "read again".
public nonisolated final class OverlayChangeFeed: Sendable {
    private nonisolated struct State {
        var next = 0
        var subscribers: [Int: AsyncStream<Void>.Continuation] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// A new subscription; it ends when the subscriber stops iterating it.
    public func subscribe() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = state.withLock { state in
            defer { state.next += 1 }
            state.subscribers[state.next] = continuation
            return state.next
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    /// Something above a window's content changed.
    public func signal() {
        let subscribers = state.withLock { Array($0.subscribers.values) }
        for continuation in subscribers { continuation.yield() }
    }

    /// Subscriptions still iterated (tests).
    public var subscriberCount: Int { state.withLock { $0.subscribers.count } }
}
