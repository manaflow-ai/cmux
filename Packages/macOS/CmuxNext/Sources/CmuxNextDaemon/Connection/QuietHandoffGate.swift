import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

/// The request side of ``DaemonConnection``'s quiet handoff, with no actor.
///
/// A request takes no lock: ``enter(passes:)`` counts it in flight, then reads the hold flag; ``leave()``
/// uncounts it, then reads whether a handoff waits for quiet. A handoff sets the hold flag, then reads the
/// count. All four use sequentially consistent order, so a request that missed the flag was counted before
/// the handoff read the count. The waiting lists (held requests, handoffs waiting for quiet or for their
/// turn) live under a short `Mutex` that only those waits take. Chrome sends IPC from any thread the same
/// way: `IPC::SyncMessageFilter::Send` (ipc/ipc_sync_message_filter.cc) reads the channel under a lock and
/// never posts to the channel owner's thread first.
final class QuietHandoffGate: Sendable {
    /// One handoff's hold. Releasing a hold that already ended does nothing, so a late timer of one
    /// handoff never ends the next one's hold.
    struct Hold: Sendable, Equatable {
        let generation: UInt64
    }

    /// A wait the gate parks (tests observe them through `observe`).
    enum Wait: Sendable, Equatable {
        /// A request waits for the hold to end.
        case request
        /// A handoff waits for the requests in flight to end.
        case quiet
        /// A handoff waits for the running handoff's hold to end.
        case queue
    }

    /// A parked request: its wait ends on release or when its task is cancelled.
    private typealias HeldRequest = OnceContinuation<Void, any Error>
    /// A parked handoff (waiting for quiet or for its turn).
    private typealias HandoffWait = OnceContinuation<Void, OnceContinuationError>

    private struct Waits {
        /// The running handoff's hold; nil while none runs. ``QuietHandoffGate/holding`` mirrors it.
        var hold: Hold?
        var generation: UInt64 = 0
        var nextKey: UInt64 = 0
        var held: [UInt64: HeldRequest] = [:]
        var quiet: [HandoffWait] = []
        var queue: [HandoffWait] = []
    }

    /// True while a handoff holds new requests; written only under `waits`' lock.
    private let holding = Atomic<Bool>(false)
    private let inFlight = Atomic<Int>(0)
    /// True while a handoff waits for quiet; written only under `waits`' lock. The last request to end
    /// takes the lock only then, so a request with no handoff waiting takes no lock at all.
    private let quietWanted = Atomic<Bool>(false)
    private let waits = Mutex(Waits())
    private let observe: @Sendable (Wait) -> Void
    /// Told each time the count of requests in flight leaves or reaches 0 (the
    /// heartbeat asks on its shown cadence while a request waits for its reply). It is told with the
    /// gate, not the edge: edges of two threads can arrive out of order, so it reads
    /// ``requestsInFlight`` under its own lock and the last reader sees the latest count.
    private let busyEdge: @Sendable (QuietHandoffGate) -> Void

    /// - Parameters:
    ///   - observe: Told each time a wait parks (a test seam; the default ignores it).
    ///   - busyEdge: Told each time the count of requests in flight leaves or reaches 0.
    init(observe: @escaping @Sendable (Wait) -> Void = { _ in },
         busyEdge: @escaping @Sendable (QuietHandoffGate) -> Void = { _ in }) {
        self.observe = observe
        self.busyEdge = busyEdge
    }

    /// Requests counted in flight (diagnostics, tests).
    var requestsInFlight: Int { inFlight.load(ordering: .sequentiallyConsistent) }

    /// True while a handoff holds new requests.
    var isHolding: Bool { holding.load(ordering: .sequentiallyConsistent) }

    /// True while `hold` is the running handoff's hold.
    func holds(_ hold: Hold) -> Bool { waits.withLock { $0.hold == hold } }

    // MARK: - Requests

    /// Counts a request in flight once no hold stops it: at once when none runs, when `passes` (the
    /// handoff's own requests), or when the task is cancelled (it goes on and fails as before). Every
    /// return must be paired with one ``leave()``.
    func enter(passes: Bool) async {
        count()
        // Each turn parks until a hold ends; a new hold after it parks the request again.
        while !passes, holding.load(ordering: .sequentiallyConsistent), !Task.isCancelled {
            leave()
            await parkUntilReleased()
            count()
        }
    }

    /// Counts one request in flight; the first tells `busyEdge`.
    private func count() {
        if inFlight.wrappingAdd(1, ordering: .sequentiallyConsistent).newValue == 1 { busyEdge(self) }
    }

    /// Ends a request that ``enter(passes:)`` counted; the last one lets a handoff waiting for quiet go on.
    func leave() {
        let left = inFlight.wrappingSubtract(1, ordering: .sequentiallyConsistent).newValue
        if left == 0 { busyEdge(self) }
        guard left == 0, quietWanted.load(ordering: .sequentiallyConsistent) else { return }
        let quiet = waits.withLock { waits -> [HandoffWait] in
            guard inFlight.load(ordering: .sequentiallyConsistent) == 0 else { return [] }
            quietWanted.store(false, ordering: .sequentiallyConsistent)
            defer { waits.quiet.removeAll() }
            return waits.quiet
        }
        quiet.forEach { $0.resume(returning: ()) }
    }

    /// Waits until the hold ends or the task is cancelled.
    private func parkUntilReleased() async {
        let key = waits.withLock { waits -> UInt64 in
            waits.nextKey &+= 1
            return waits.nextKey
        }
        // A cancelled wait ends with CancellationError; the request then goes on, as a released one does.
        _ = try? await withOnceThrowingContinuation(cancellation: .cancellable) { (continuation: HeldRequest) in
            let parked = waits.withLock { waits -> Bool in
                guard waits.hold != nil else { return false }
                waits.held[key] = continuation
                return true
            }
            if parked {
                observe(.request)
            } else {
                continuation.resume(returning: ())
            }
        }
        // A cancelled wait leaves its entry; a released one was taken already.
        waits.withLock { waits in _ = waits.held.removeValue(forKey: key) }
    }

    // MARK: - Handoffs

    /// Starts a handoff's hold once the previous handoff's hold ended, then returns once no request is in
    /// flight. New requests wait in ``enter(passes:)`` until ``release(_:)``.
    func beginHandoff() async -> Hold {
        let hold = await takeHoldInTurn()
        await waitUntilQuiet()
        return hold
    }

    /// Takes the hold, after the running one ends; another queued handoff may take it first, and then
    /// this one waits for that hold too.
    private func takeHoldInTurn() async -> Hold {
        if let hold = takeHold() { return hold }
        await waitForQueueTurn()
        return await takeHoldInTurn()
    }

    /// Starts a hold when none runs.
    private func takeHold() -> Hold? {
        waits.withLock { waits -> Hold? in
            guard waits.hold == nil else { return nil }
            waits.generation &+= 1
            let hold = Hold(generation: waits.generation)
            waits.hold = hold
            holding.store(true, ordering: .sequentiallyConsistent)
            return hold
        }
    }

    /// Waits until the running hold ends (at once when none runs).
    private func waitForQueueTurn() async {
        // A queued waiter dropped unresumed goes on as a resumed one does.
        _ = try? await withOnceContinuation { (next: HandoffWait) in
            let queued = waits.withLock { waits -> Bool in
                guard waits.hold != nil else { return false }
                waits.queue.append(next)
                return true
            }
            if queued {
                observe(.queue)
            } else {
                next.resume(returning: ())
            }
        }
    }

    /// Waits until no request is in flight (at once when none is).
    private func waitUntilQuiet() async {
        // A quiet waiter dropped unresumed goes on as a resumed one does.
        _ = try? await withOnceContinuation { (quiet: HandoffWait) in
            let waiting = waits.withLock { waits -> Bool in
                // Flag first, then read the count: a request that ends after the read sees the flag.
                quietWanted.store(true, ordering: .sequentiallyConsistent)
                guard inFlight.load(ordering: .sequentiallyConsistent) > 0 else {
                    if waits.quiet.isEmpty { quietWanted.store(false, ordering: .sequentiallyConsistent) }
                    return false
                }
                waits.quiet.append(quiet)
                return true
            }
            if waiting {
                observe(.quiet)
            } else {
                quiet.resume(returning: ())
            }
        }
    }

    /// Ends `hold` (nil: whichever runs): the held requests go on, then the next queued handoff. Returns
    /// false when that hold had ended already.
    @discardableResult
    func release(_ hold: Hold? = nil) -> Bool {
        let woken = waits.withLock { waits -> (held: [HeldRequest], queue: [HandoffWait])? in
            guard let current = waits.hold, hold == nil || hold == current else { return nil }
            waits.hold = nil
            holding.store(false, ordering: .sequentiallyConsistent)
            defer {
                waits.held.removeAll()
                waits.queue.removeAll()
            }
            return (Array(waits.held.values), waits.queue)
        }
        guard let woken else { return false }
        woken.held.forEach { $0.resume(returning: ()) }
        woken.queue.forEach { $0.resume(returning: ()) }
        return true
    }
}
