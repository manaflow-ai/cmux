import CmuxNextDaemon
public import CmuxNextWakeups

/// `energy.set` (cmux-tui-core server/energy_op.rs, p14-energy-033): the app's Energy Saver, an
/// override of the daemon's own reading that lasts as long as the connection that sent it. `reason`
/// is the policy's ``EnergyPolicy/Reason`` and goes only with `saver: true`; nil is left out of the line.
nonisolated struct EnergySetRequest: DaemonRequest, Equatable {
    typealias Response = EmptyResponse
    static let commandName: DaemonCommandName = "energy.set"
    /// The capability a daemon that answers `energy.set` advertises.
    static let capability = "energy-v1"
    static var requiredCapability: String? { capability }
    var saver: Bool
    var reason: String?
}

/// What the local daemon has been told of Energy Saver, so the app sends `energy.set` only on an edge
/// of `isSaver`: Chrome's `BatterySaverModeManager` tells each child process once per edge
/// (content/child/child_thread_impl.cc `SetBatterySaverMode`). A policy change that keeps the saver
/// (sleep, power source) is no edge; nor is the policy the app holds when it starts following.
///
/// A new connection has been told nothing (the daemon drops the override of a connection that ended),
/// so each connection is told the current value once.
nonisolated struct DaemonEnergyEdges: Sendable, Equatable {
    /// The app's saver as last seen.
    private(set) var saver: Bool
    /// What this connection was told; nil until it is told, and while there is no connection.
    private(set) var told: Bool?

    init(saver: Bool) {
        self.saver = saver
    }

    /// The app's policy changed: the value to send, or nil when the saver did not flip for this
    /// connection (or there is none).
    mutating func observe(saver: Bool, connected: Bool) -> Bool? {
        self.saver = saver
        return connected ? pending() : nil
    }

    /// A connection came up while the app's saver is `saver`: the value to tell it.
    mutating func connected(saver: Bool) -> Bool? {
        self.saver = saver
        told = nil
        return pending()
    }

    /// The connection went away; the next one is told afresh.
    mutating func disconnected() {
        told = nil
    }

    private mutating func pending() -> Bool? {
        guard told != saver else { return nil }
        told = saver
        return saver
    }
}

/// Tells the local daemon each edge of the app's Energy Saver. It observes the app's
/// ``EnergyPolicySource`` and the store's connection, which is its one meaning of connected: each
/// `.connected` epoch (a first connect, a reconnect, a restarted daemon) is told the current value,
/// and an edge while disconnected waits for the next one. The source and the store are held weakly.
final class DaemonEnergyFollow {
    /// Sends one `energy.set` to the connected daemon.
    typealias Send = @MainActor @Sendable (EnergySetRequest) async -> Void

    private weak var source: EnergyPolicySource?
    private weak var store: DaemonStore?
    private var observation: MainActorEnergyObservation?
    private var link: ServiceObservation<Int?>?
    /// The store's connection epoch while it is connected; nil while it is not.
    private(set) var connection: Int?
    private(set) var edges: DaemonEnergyEdges
    /// The latest `energy.set` not yet sent (newest one kept), and the one pump off main that sends it.
    private let requests: AsyncStream<EnergySetRequest>.Continuation
    private let pump: Task<Void, Never>

    /// - Parameters:
    ///   - source: The app's one policy source (``MainWorkScheduler/energy``).
    ///   - store: The local daemon's store; its ``DaemonStore/connectionState`` and
    ///     ``DaemonStore/connectionEpoch`` say which connection is up.
    ///   - work: The app's main-thread scheduler, for the connection observation.
    ///   - send: Sends one request (``DaemonService/run(_:_:)`` in the app; a recorder in tests).
    init(_ source: EnergyPolicySource, store: DaemonStore, on work: MainWorkScheduler, send: @escaping Send) {
        self.source = source
        self.store = store
        edges = DaemonEnergyEdges(saver: source.policy.isSaver)
        let (stream, requests) = AsyncStream.makeStream(of: EnergySetRequest.self, bufferingPolicy: .bufferingNewest(1))
        self.requests = requests
        // task-owner: this follower; deinit finishes the stream, which ends the pump
        pump = Task { @concurrent in
            for await request in stream { await send(request) }
        }
        observation = MainActorEnergyObservation(source) { [weak self] _ in self?.changed() }
        // `background`: nothing on screen waits for the daemon's saver.
        link = ServiceObservation<Int?>(.background, owner: "DaemonEnergyFollow.connection", on: work) { [weak store] () -> Int? in
            guard let store, case .connected = store.connectionState else { return nil }
            return store.connectionEpoch
        } apply: { [weak self] epoch in
            self?.linked(epoch)
        }
    }

    deinit {
        requests.finish()
    }

    /// The store's connection is `epoch` (nil: none): a new one is told the saver the app holds now.
    private func linked(_ epoch: Int?) {
        connection = epoch
        guard epoch != nil else {
            edges.disconnected()
            return
        }
        guard let policy = source?.policy else { return }
        tell(edges.connected(saver: policy.isSaver), reason: policy.reason)
    }

    /// The app's policy changed: tells the daemon when the saver flipped.
    func changed() {
        guard let policy = source?.policy else { return }
        tell(edges.observe(saver: policy.isSaver, connected: connection != nil), reason: policy.reason)
    }

    /// Sends `saver` when there is one to send and the daemon serves `energy.set` (an older daemon
    /// does not; it is skipped, not failed). The pump sends one at a time and keeps only the newest
    /// unsent value, so an on and an off in quick succession reach the daemon in that order.
    private func tell(_ saver: Bool?, reason: EnergyPolicy.Reason?) {
        guard let saver, store?.supports(EnergySetRequest.capability) == true else { return }
        requests.yield(EnergySetRequest(saver: saver, reason: saver ? reason?.rawValue : nil))
    }
}

extension DaemonService {
    /// Tells the local daemon each Energy Saver edge (`energy.set`); a Cloud machine's daemon does
    /// not follow this Mac's power. The composition root calls it once with ``MainWorkScheduler/energy``.
    public func follow(_ energy: EnergyPolicySource, on work: MainWorkScheduler) {
        guard isLocal, energyFollow == nil else { return }
        energyFollow = DaemonEnergyFollow(energy, store: store, on: work) { [weak self] request in
            _ = await self?.run("energy.set") { _ = try await $0.request(request) }
        }
    }
}
