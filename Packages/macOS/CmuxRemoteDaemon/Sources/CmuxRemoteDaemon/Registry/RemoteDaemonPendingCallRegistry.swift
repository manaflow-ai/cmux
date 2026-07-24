public import Foundation

/// Pairs outgoing daemon RPC request ids with the threads blocked on their
/// responses (faithful lift of the app target's
/// `WorkspaceRemoteDaemonPendingCallRegistry`).
///
/// Isolation design (queue + semaphore, deliberately not an actor):
/// - **Who mutates:** `register`/`resolve`/`failAll`/`remove`/`reset` run from
///   arbitrary caller threads and from the RPC client's state queue; every
///   mutation of `nextRequestID` and `pendingCalls` hops through the private
///   serial `queue` via `queue.sync`.
/// - **Who reads:** the caller of ``wait(for:timeout:)`` blocks its own thread
///   on the call's `DispatchSemaphore` (it cannot await; the daemon RPC
///   surface is synchronous by contract), then re-enters `queue` to consume
///   the result. The semaphore signal in `resolve`/`failAll` is the
///   happens-before edge that publishes `response`/`failureMessage` to the
///   waiter.
/// - **Why this primitive:** callers block synchronously while responses
///   arrive from the transport reader thread; an actor would force `await`
///   into synchronous call sites and reentrancy would reorder
///   resolve-vs-timeout races that the current design settles with one
///   blocking critical section. Migrating this to async/await is a deliberate
///   later-phase item (plan: "Modernization hot-spots (migrate in a later
///   phase)").
public final class RemoteDaemonPendingCallRegistry: @unchecked Sendable {
    // @unchecked Sendable: all mutable state (`nextRequestID`, `pendingCalls`,
    // and each PendingCall's fields) is confined to `queue`; semaphores carry
    // results across threads with a signal->wait happens-before edge.

    /// One in-flight RPC call: the id on the wire and the semaphore its
    /// caller blocks on until ``RemoteDaemonPendingCallRegistry/resolve(id:payload:)``
    /// or ``RemoteDaemonPendingCallRegistry/failAll(_:)`` signals it.
    public final class PendingCall: @unchecked Sendable {
        // @unchecked Sendable: `response`/`failureMessage` are written only on
        // the registry queue before `semaphore.signal()`; the waiter reads
        // them only after a successful wait, back on the registry queue.

        /// The wire request id (`"id"` in the JSON frame; do not renumber).
        public let id: Int
        fileprivate let semaphore = DispatchSemaphore(value: 0)
        fileprivate var response: [String: Any]?
        fileprivate var failureMessage: String?

        fileprivate init(id: Int) {
            self.id = id
        }
    }

    /// The outcome of blocking on one pending call.
    public enum WaitOutcome {
        /// The daemon answered; payload is the raw decoded JSON response frame.
        case response([String: Any])
        /// The transport failed the call (e.g. it closed); payload is the
        /// failure detail.
        case failure(String)
        /// The call was no longer registered when the waiter woke up.
        case missing
        /// No response arrived within the timeout; the call was removed.
        case timedOut
    }

    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.pending.\(UUID().uuidString)")
    private var nextRequestID = 1
    private var pendingCalls: [Int: PendingCall] = [:]

    /// Creates an empty registry; ids start at 1.
    public init() {}

    /// Drops every pending call and restarts request ids at 1 (called when a
    /// transport (re)starts).
    public func reset() {
        queue.sync {
            nextRequestID = 1
            pendingCalls.removeAll(keepingCapacity: false)
        }
    }

    /// Allocates the next request id and registers a call for it.
    public func register() -> PendingCall {
        queue.sync {
            let call = PendingCall(id: nextRequestID)
            nextRequestID += 1
            pendingCalls[call.id] = call
            return call
        }
    }

    /// Delivers a response payload to the pending call with `id` and wakes its
    /// waiter. Returns `false` when no such call is registered (e.g. it timed
    /// out and was removed).
    @discardableResult
    public func resolve(id: Int, payload: [String: Any]) -> Bool {
        queue.sync {
            guard let pendingCall = pendingCalls[id] else { return false }
            pendingCall.response = payload
            pendingCall.semaphore.signal()
            return true
        }
    }

    /// Fails every still-unanswered pending call with `message` and wakes its
    /// waiter (transport closed/stopped).
    public func failAll(_ message: String) {
        queue.sync {
            let calls = Array(pendingCalls.values)
            for call in calls {
                guard call.response == nil, call.failureMessage == nil else { continue }
                call.failureMessage = message
                call.semaphore.signal()
            }
        }
    }

    /// Unregisters a call without signaling it (the request was never
    /// written, so nothing will ever resolve it).
    public func remove(_ call: PendingCall) {
        _ = queue.sync {
            pendingCalls.removeValue(forKey: call.id)
        }
    }

    /// Blocks the calling thread until `call` resolves, fails, or `timeout`
    /// elapses. A timed-out call is removed; a response that races the
    /// timeout is drained so the semaphore never deallocates with a positive
    /// count.
    public func wait(for call: PendingCall, timeout: TimeInterval) -> WaitOutcome {
        if call.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            _ = queue.sync {
                pendingCalls.removeValue(forKey: call.id)
            }
            // A response can win the race immediately before timeout cleanup removes the call.
            // Drain any late signal so DispatchSemaphore is not deallocated with a positive count.
            _ = call.semaphore.wait(timeout: .now())
            return .timedOut
        }

        return queue.sync {
            guard let pendingCall = pendingCalls.removeValue(forKey: call.id) else {
                return .missing
            }
            if let failure = pendingCall.failureMessage {
                return .failure(failure)
            }
            guard let response = pendingCall.response else {
                return .missing
            }
            return .response(response)
        }
    }
}
