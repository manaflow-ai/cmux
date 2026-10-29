public import CmuxNextCompat
public import CmuxNextWakeups

/// `memory.limit` (cmux-tui-core server/memory_limit.rs): the app's memory pressure level (its
/// debug override folded in), its Memory Saver mode and the debug override itself. The daemon votes the level
/// next to its own kernel source and its consumers hear the worse of the two, as Chrome's browser hands each
/// child process its limit through `ChildMemoryConsumerRegistryHost` and the most restrictive one wins
/// (content/browser/memory_coordinator/README.md). The daemon passes it on to acpmux. The vote lasts as long as
/// the connection that sent it; `override` is left out of the line while nil.
public struct MemoryLimitRequest: DaemonRequest, Equatable {
    public typealias Response = EmptyResponse
    public static let commandName: DaemonCommandName = "memory.limit"
    /// The capability a daemon that answers `memory.limit` advertises.
    public static let capability = "memory-limit-v1"
    public static var requiredCapability: String? { capability }

    /// The level the app's coordinator acts on: the debug override when set, else the kernel's.
    public var level: MemoryPressureLevel
    /// The `memory.saver` mode.
    public var mode: MemorySaverMode
    /// The debug override (`debug.hibernation.pressure`); nil while none is set.
    public var pressureOverride: MemoryPressureLevel?

    public init(level: MemoryPressureLevel, mode: MemorySaverMode, pressureOverride: MemoryPressureLevel? = nil) {
        self.level = level
        self.mode = mode
        self.pressureOverride = pressureOverride
    }

    enum CodingKeys: String, CodingKey {
        case level, mode
        case pressureOverride = "override"
    }
}

/// What the local daemon has been told of the app's memory limit, so the app sends `memory.limit` only on a
/// change: Chrome's browser updates a child's limit only when it changes. A new connection has been told
/// nothing (the daemon drops the limit of a connection that ended), so each connection is told the current
/// limit once.
public struct DaemonMemoryLimitEdges: Sendable, Equatable {
    /// The app's limit as last seen.
    public private(set) var value: MemoryLimitRequest
    /// What this connection was told; nil until it is told, and while there is no connection.
    public private(set) var told: MemoryLimitRequest?

    public init(_ value: MemoryLimitRequest) {
        self.value = value
    }

    /// The app's limit changed: the limit to send, or nil when this connection already has it (or there is
    /// none).
    public mutating func observe(_ value: MemoryLimitRequest, connected: Bool) -> MemoryLimitRequest? {
        self.value = value
        return connected ? pending() : nil
    }

    /// A connection came up: the limit to tell it.
    public mutating func connected() -> MemoryLimitRequest? {
        told = nil
        return pending()
    }

    /// The connection went away; the next one is told afresh.
    public mutating func disconnected() {
        told = nil
    }

    private mutating func pending() -> MemoryLimitRequest? {
        guard told != value else { return nil }
        told = value
        return value
    }
}

/// Tells the local daemon each change of the app's memory limit. The app's memory coordinator hands it each
/// level and mode (``changed(_:)``); it observes the store's connection, so each `.connected` epoch (a first
/// connect, a reconnect, a restarted daemon) is told the current limit, and a change while disconnected waits
/// for the next one. A daemon without ``MemoryLimitRequest/capability`` is skipped. The store is held weakly.
@MainActor
public final class DaemonMemoryLimitFollow {
    /// Sends one `memory.limit` to the connected daemon.
    public typealias Send = @MainActor @Sendable (MemoryLimitRequest) async -> Void

    private weak var store: DaemonStore?
    private var link: ServiceObservation<Int?>?
    /// The store's connection epoch while it is connected; nil while it is not.
    public private(set) var connection: Int?
    public private(set) var edges: DaemonMemoryLimitEdges
    /// The latest `memory.limit` not yet sent (newest one kept), and the one pump off main that sends it.
    private let requests: AsyncStream<MemoryLimitRequest>.Continuation
    private let pump: Task<Void, Never>

    /// - Parameters:
    ///   - initial: The app's limit now.
    ///   - store: The local daemon's store; its ``DaemonStore/connectionState`` and
    ///     ``DaemonStore/connectionEpoch`` say which connection is up.
    ///   - work: The app's main-thread scheduler, for the connection observation.
    ///   - send: Sends one request (`DaemonService.run(_:_:)` in the app; a recorder in tests).
    public init(_ initial: MemoryLimitRequest, store: DaemonStore, on work: MainWorkScheduler, send: @escaping Send) {
        self.store = store
        edges = DaemonMemoryLimitEdges(initial)
        let (stream, requests) = AsyncStream.makeStream(of: MemoryLimitRequest.self, bufferingPolicy: .bufferingNewest(1))
        self.requests = requests
        // task-owner: this follower; deinit finishes the stream, which ends the pump
        pump = Task { @concurrent in
            for await request in stream { await send(request) }
        }
        // `background`: nothing on screen waits for the daemon's limit.
        link = ServiceObservation<Int?>(.background, owner: "DaemonMemoryLimitFollow.connection", on: work) { [weak store] () -> Int? in
            guard let store, case .connected = store.connectionState else { return nil }
            return store.connectionEpoch
        } apply: { [weak self] epoch in
            self?.linked(epoch)
        }
    }

    nonisolated deinit {
        requests.finish()
    }

    /// The app's limit is `value` now: tells the daemon when it changed.
    public func changed(_ value: MemoryLimitRequest) {
        tell(edges.observe(value, connected: connection != nil))
    }

    /// The store's connection is `epoch` (nil: none): a new one is told the limit the app holds now.
    private func linked(_ epoch: Int?) {
        connection = epoch
        guard epoch != nil else {
            edges.disconnected()
            return
        }
        tell(edges.connected())
    }

    /// Queues `request` for the pump when there is one and the daemon serves `memory.limit`. The pump sends
    /// one at a time and keeps only the newest unsent limit.
    private func tell(_ request: MemoryLimitRequest?) {
        guard let request, let store, store.supports(MemoryLimitRequest.capability) else { return }
        requests.yield(request)
    }
}
