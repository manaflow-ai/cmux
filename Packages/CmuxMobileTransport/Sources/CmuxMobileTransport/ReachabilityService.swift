import Foundation
@preconcurrency import Network

/// A de-singletonized network-reachability monitor backed by `NWPathMonitor`.
///
/// Owns the path monitor and its callback queue, tracks the current online
/// state and primary interface type as actor-isolated state, and fans
/// meaningful path changes out to any number of subscribers through
/// ``pathChanges()``.
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
    private var lastInterfaceType: NWInterface.InterfaceType?
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

    /// A stream that yields once per meaningful path change.
    /// - Returns: An `AsyncStream` removed from the registry when its consumer
    ///   stops iterating or the task is cancelled.
    public nonisolated func pathChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let registration = Task { await self.register(continuation) }
            continuation.onTermination = { _ in
                registration.cancel()
                Task { await self.unregister(awaiting: registration) }
            }
        }
    }

    private func register(_ continuation: AsyncStream<Void>.Continuation) -> Int {
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
            // Compute Sendable values on the monitor queue; never capture NWPath.
            let isSatisfied = path.status == .satisfied
            let primaryType = ReachabilityService.primaryInterfaceType(of: path)
            Task { await self?.apply(online: isSatisfied, primaryType: primaryType) }
        }
        monitor.start(queue: queue)
    }

    private func apply(online: Bool, primaryType: NWInterface.InterfaceType?) {
        let wasOnline = self.online
        let previousType = lastInterfaceType
        self.online = online
        if online { lastInterfaceType = primaryType }
        if !receivedFirstPath {
            receivedFirstPath = true
            for waiter in firstPathWaiters.values {
                waiter.resume()
            }
            firstPathWaiters.removeAll()
            cancelledFirstPathWaiterIDs.removeAll()
        }
        let regainedOnline = online && !wasOnline
        let interfaceChanged = online && previousType != nil && primaryType != previousType
        guard regainedOnline || interfaceChanged else { return }
        for continuation in subscribers.values {
            continuation.yield(())
        }
    }

    private nonisolated static func primaryInterfaceType(
        of path: NWPath
    ) -> NWInterface.InterfaceType? {
        for type in [NWInterface.InterfaceType.wifi, .wiredEthernet, .cellular]
        where path.usesInterfaceType(type) {
            return type
        }
        return path.availableInterfaces.first?.type
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
