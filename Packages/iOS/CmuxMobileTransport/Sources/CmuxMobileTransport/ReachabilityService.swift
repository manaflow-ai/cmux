import Foundation
@preconcurrency import Network

/// A de-singletonized network-reachability monitor backed by `NWPathMonitor`.
///
/// Owns the path monitor and its callback queue, tracks the current online
/// state as actor-isolated state, and fans post-initial path updates out to any
/// number of subscribers through ``pathChanges()``.
///
/// Construct it once at the app composition root and inject it as
/// `any ReachabilityProviding`:
///
/// ```swift
/// let reachability = ReachabilityService()
/// guard await reachability.isOnline else { throw AuthError.offline }
/// for await _ in reachability.pathChanges() { await recover() }
/// ```
public actor ReachabilityService: ReachabilityProviding {
    private let monitor: NWPathMonitor
    // Network.framework requires a callback queue; its handler re-enters the actor.
    private let queue: DispatchQueue
    private var started = false
    private var online = true
    private var nextSubscriptionID = 0
    private var subscribers: [Int: AsyncStream<Void>.Continuation] = [:]
    /// Whether `NWPathMonitor` has delivered its first path since `start`.
    /// Until then the cached `online` value is just the optimistic initial
    /// constant, so ``isOnline`` must not answer from it (a cold-launch offline
    /// pairing preflight would wrongly see `true` and dial into the slow
    /// timeout path this preflight exists to avoid).
    private var receivedFirstPath = false
    private var firstPathWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextFirstPathWaiterID = 0
    /// Waiter IDs whose cancellation handler ran before the waiter stored its
    /// continuation (a task cancelled right as it began waiting), so the store
    /// step resumes immediately instead of parking a dead task.
    private var cancelledFirstPathWaiterIDs: Set<Int> = []

    /// Creates a reachability monitor and begins observing path updates.
    ///
    /// Monitoring starts lazily on the first observation so a freshly
    /// constructed instance is cheap; ``isOnline`` and ``pathChanges()`` both
    /// arm it.
    public init() {
        monitor = NWPathMonitor()
        queue = DispatchQueue(label: "dev.cmux.network-reachability", qos: .utility)
    }

    /// Whether the system currently has a satisfied network path.
    ///
    /// Suspends until `NWPathMonitor` has delivered its first path (it posts
    /// the current path promptly on `start`), so the answer always reflects a
    /// real observation instead of the optimistic initial constant.
    public var isOnline: Bool {
        get async {
            startIfNeeded()
            await waitForFirstPathIfNeeded()
            return online
        }
    }

    /// Parks the caller until the first path delivery, honoring task
    /// cancellation: a cancelled waiter resumes immediately (the caller then
    /// reads the provisional `online` value and its own cancellation checks
    /// take over) instead of staying suspended until the monitor fires.
    private func waitForFirstPathIfNeeded() async {
        guard !receivedFirstPath else { return }
        let id = nextFirstPathWaiterID
        nextFirstPathWaiterID += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if receivedFirstPath || cancelledFirstPathWaiterIDs.remove(id) != nil || Task.isCancelled {
                    continuation.resume()
                    return
                }
                firstPathWaiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelFirstPathWaiter(id: id) }
        }
    }

    private func cancelFirstPathWaiter(id: Int) {
        if let continuation = firstPathWaiters.removeValue(forKey: id) {
            continuation.resume()
        } else {
            cancelledFirstPathWaiterIDs.insert(id)
        }
    }

    /// A stream that yields once per path update after the initial snapshot.
    /// - Returns: An `AsyncStream` removed from the registry when its consumer
    ///   stops iterating or the task is cancelled.
    public nonisolated func pathChanges() -> AsyncStream<Void> {
        // Recovery only needs the newest pending security boundary; bounding
        // the stream prevents callback bursts from queuing unbounded work.
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let registration = Task { await self.register(continuation) }
            continuation.onTermination = { _ in
                registration.cancel()
                Task { await self.unregister(awaiting: registration) }
            }
        }
    }

    func register(_ continuation: AsyncStream<Void>.Continuation) -> Int {
        startIfNeeded()
        let id = nextSubscriptionID
        nextSubscriptionID += 1
        subscribers[id] = continuation
        return id
    }

    private func unregister(awaiting registration: Task<Int, Never>) async {
        let id = await registration.value
        subscribers.removeValue(forKey: id)
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            // Compute Sendable state on the monitor queue; never capture NWPath.
            let isSatisfied = path.status == .satisfied
            Task { await self?.apply(online: isSatisfied) }
        }
        monitor.start(queue: queue)
    }

    func apply(online: Bool) {
        let isInitialPath = !receivedFirstPath
        self.online = online
        if isInitialPath {
            receivedFirstPath = true
            for waiter in firstPathWaiters.values {
                waiter.resume()
            }
            firstPathWaiters.removeAll()
            cancelledFirstPathWaiterIDs.removeAll()
        }
        guard !isInitialPath else { return }
        for continuation in subscribers.values {
            continuation.yield(())
        }
    }

    deinit {
        monitor.cancel()
        for continuation in subscribers.values {
            continuation.finish()
        }
        for waiter in firstPathWaiters.values {
            waiter.resume()
        }
    }
}
