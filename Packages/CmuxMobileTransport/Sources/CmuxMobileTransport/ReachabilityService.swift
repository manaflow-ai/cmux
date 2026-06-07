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
    public var isOnline: Bool {
        startIfNeeded()
        return online
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
    }
}
