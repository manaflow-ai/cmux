import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

extension DaemonConnection {
    /// Another consumer of this connection's events: every later event `filter` matches, in the
    /// connection's order, across reconnects (`connected` and `disconnected` included when the
    /// filter keeps them), until the connection closes. The reader appends to the subscriber's own
    /// inbox and never waits for it: past `limit` held events the inbox drops them and yields one
    /// ``DaemonSubscriptionItem/resync``, to this subscriber only. Subscribe before reading the
    /// state the events change, so none falls between the read and the subscription.
    ///
    /// - Parameters:
    ///   - filter: Picks the events; runs on the reader thread for each event (``DaemonEventFilter``).
    ///   - limit: The most events the inbox holds before it resyncs.
    public nonisolated func subscribe(filter: DaemonEventFilter = .all,
                                      limit: Int = DaemonEventSubscription.defaultLimit) -> DaemonEventSubscription {
        route.subscribe(filter: filter, limit: limit)
    }

    /// For a connection that serves requests only (its handshake subscribes anyway): takes `events`
    /// and drops every event no subscriber asked for, so nothing buffers and no task drains them.
    public nonisolated func discardEvents() {
        route.discardStream()
    }
}

/// Which events a ``DaemonEventSubscription`` gets. Runs on the thread that emits each event (the
/// connection's reader for daemon events), under the connection's route lock: it must only look at
/// the event, never block or call back into the connection.
public struct DaemonEventFilter: Sendable {
    let matches: @Sendable (DaemonEvent) -> Bool

    /// A filter that keeps the events `matches` returns true for.
    public init(_ matches: @escaping @Sendable (DaemonEvent) -> Bool) {
        self.matches = matches
    }

    /// Every event.
    public static let all = DaemonEventFilter { _ in true }
}

/// What a ``DaemonEventSubscription`` yields.
public enum DaemonSubscriptionItem: Sendable, Hashable {
    /// The next event the filter matched, in the connection's order.
    case event(DaemonEventEnvelope)
    /// The subscriber fell `limit` events behind: the events it held and the ones that came while it
    /// was full are gone. Re-read what it mirrors; the events after this one follow the re-read's
    /// moment. One per overflow, however far it fell behind.
    case resync
}

/// One more consumer of a ``DaemonConnection``'s events, next to the one that takes `events` (the
/// store): ``DaemonConnection/subscribe(filter:limit:)``. It gets every later event its filter
/// matches, in order, into a bounded inbox of its own; the reader only appends to the inbox, so a
/// subscriber that stops reading delays no other consumer, the store included. When it falls
/// `limit` events behind, its inbox drops what it holds and yields one ``DaemonSubscriptionItem/resync``
/// (only to that subscriber). It ends when the connection closes (after the events it still
/// holds), when the consuming task is cancelled, on ``cancel()``, or when the last reference goes.
///
/// Chromium's IPC message filters (ipc/ipc_channel_proxy.cc, `ChannelProxy::Context::AddFilter`)
/// each see every message on the IO thread and none waits for another; mojo bounds what a receiver
/// leaves unread (`MOJO_QUOTA_TYPE_UNREAD_MESSAGE_COUNT`, mojo/public/cpp/bindings/message_quota_checker.h).
/// Where mojo ends the pipe at its quota, a subscriber here re-reads.
public final class DaemonEventSubscription: AsyncSequence, Sendable {
    public typealias Element = DaemonSubscriptionItem

    /// Matches the daemon's own per-client mailbox and the store's inbox.
    public static let defaultLimit = 4096

    let inbox: Inbox
    private let onEnd: @Sendable () -> Void

    init(inbox: Inbox, onEnd: @escaping @Sendable () -> Void) {
        self.inbox = inbox
        self.onEnd = onEnd
    }

    deinit {
        cancel()
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(subscription: self)
    }

    /// Ends the subscription now: no later event, the ones it holds dropped. Idempotent.
    public func cancel() {
        inbox.finish(dropping: true)
        onEnd()
    }

    /// The resyncs this subscription yielded or holds.
    public var resyncCount: Int { inbox.resyncs }

    public struct Iterator: AsyncIteratorProtocol {
        public typealias Failure = Never

        let subscription: DaemonEventSubscription

        /// The next item, or nil once the subscription ended. One consumer: a second concurrent
        /// `next()` traps in Debug.
        public mutating func next() async -> DaemonSubscriptionItem? {
            guard let item = await subscription.inbox.next() else {
                subscription.cancel()
                return nil
            }
            return item
        }
    }

    /// The subscriber's bounded inbox: the route appends on the emitting thread, the consumer takes.
    final class Inbox: Sendable {
        private enum Take {
            case item(DaemonSubscriptionItem)
            case ended
            case empty
        }

        private struct State {
            /// Held events from `head` on (taken ones before it are compacted away).
            var items: [DaemonEventEnvelope] = []
            var head = 0
            var resyncPending = false
            var resyncs = 0
            var finished = false
            /// The consumer waiting for the next item; set only while nothing is held.
            var waiter: OnceContinuation<DaemonSubscriptionItem?, OnceContinuationError>?

            var held: Int { items.count - head }

            mutating func take() -> Take {
                if resyncPending {
                    resyncPending = false
                    return .item(.resync)
                }
                guard let envelope = items[checked: head] else { return finished ? .ended : .empty }
                head += 1
                if head == items.count {
                    items.removeAll(keepingCapacity: true)
                    head = 0
                } else if head >= 1024, head * 2 >= items.count {
                    items.removeFirst(head)
                    head = 0
                }
                return .item(.event(envelope))
            }

            mutating func drop() {
                items.removeAll(keepingCapacity: true)
                head = 0
            }
        }

        let filter: DaemonEventFilter
        let limit: Int
        private let state = Mutex(State())

        init(filter: DaemonEventFilter, limit: Int) {
            self.filter = filter
            self.limit = Swift.max(limit, 1)
        }

        /// Appends `envelope` when the filter matches it, or hands it to the waiting consumer. Never
        /// waits: a full inbox drops what it holds and owes its consumer one resync.
        func offer(_ envelope: DaemonEventEnvelope) {
            guard filter.matches(envelope.event) else { return }
            let waiter = state.withLock { state -> OnceContinuation<DaemonSubscriptionItem?, OnceContinuationError>? in
                guard !state.finished else { return nil }
                if let waiter = state.waiter {
                    state.waiter = nil
                    return waiter
                }
                if state.held >= limit {
                    state.drop()
                    if !state.resyncPending {
                        state.resyncPending = true
                        state.resyncs += 1
                    }
                } else {
                    state.items.append(envelope)
                }
                return nil
            }
            waiter?.resume(returning: .event(envelope))
        }

        /// The next item; waits while none is held; nil once the inbox ended and holds nothing, or
        /// once the consuming task is cancelled (the held items dropped), as `AsyncStream` does.
        func next() async -> DaemonSubscriptionItem? {
            if Task.isCancelled {
                finish(dropping: true)
                return nil
            }
            switch state.withLock({ $0.take() }) {
            case .item(let item): return item
            case .ended: return nil
            case .empty: break
            }
            return await withTaskCancellationHandler {
                // A consumer dropped unresumed reads the inbox as ended.
                try? await withOnceContinuation { (continuation: OnceContinuation<DaemonSubscriptionItem?, OnceContinuationError>) in
                    let ready = state.withLock { state -> Take in
                        let ready = state.take()
                        if case .empty = ready {
                            assert(state.waiter == nil, "a DaemonEventSubscription has one consumer")
                            state.waiter = continuation
                        }
                        return ready
                    }
                    switch ready {
                    case .item(let item): continuation.resume(returning: item)
                    case .ended: continuation.resume(returning: nil)
                    case .empty: break
                    }
                }
            } onCancel: {
                finish(dropping: true)
            }
        }

        /// Ends the inbox: no later event; with `dropping`, the held ones go too. The waiting
        /// consumer gets nil.
        func finish(dropping: Bool = false) {
            let waiter = state.withLock { state -> OnceContinuation<DaemonSubscriptionItem?, OnceContinuationError>? in
                state.finished = true
                if dropping {
                    state.drop()
                    state.resyncPending = false
                }
                let waiter = state.waiter
                state.waiter = nil
                return waiter
            }
            waiter?.resume(returning: nil)
        }

        var resyncs: Int { state.withLock { $0.resyncs } }

        /// Events held now (tests).
        var held: Int { state.withLock { $0.held } }
    }
}
