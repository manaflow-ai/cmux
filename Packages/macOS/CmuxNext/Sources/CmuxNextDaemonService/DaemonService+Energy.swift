import CmuxNextDaemon
public import CmuxNextWakeups

/// `energy.set` (cmux-tui-core server/energy_op.rs): the app's Energy Saver, an
/// override of the daemon's own reading that lasts as long as the connection that sent it. `reason`
/// is the policy's ``EnergyPolicy/Reason`` and goes only with `saver: true`; nil is left out of the line.
/// `offForNow` ("Turn Off for Now", ``ruleCapability`` only) outlives the connection: the daemon's own
/// reading, which follows the app's rule from `energy.saver` and the Mac's power inputs
/// (server/energy_rule.rs), keeps it until the Mac is plugged in.
nonisolated struct EnergySetRequest: DaemonRequest, Equatable {
    typealias Response = EmptyResponse
    static let commandName: DaemonCommandName = "energy.set"
    /// The capability a daemon that answers `energy.set` advertises.
    static let capability = "energy-v1"
    /// The capability a daemon that takes `offForNow` advertises.
    static let ruleCapability = "energy-v2"
    static var requiredCapability: String? { capability }
    var saver: Bool
    var reason: String?
    var offForNow: Bool?
}

/// What the app tells the local daemon of its Energy Saver: the saver, and "Turn Off for Now", which
/// the daemon keeps after the app quits.
nonisolated struct DaemonEnergyValue: Sendable, Equatable {
    var saver: Bool
    var offForNow: Bool

    init(saver: Bool, offForNow: Bool = false) {
        self.saver = saver
        self.offForNow = offForNow
    }

    init(_ policy: EnergyPolicy) {
        self.init(saver: policy.isSaver, offForNow: policy.isOffForNow)
    }
}

/// What the local daemon has been told of Energy Saver, so the app sends `energy.set` only on an edge
/// of the saver or of "Turn Off for Now" (``DaemonEnergyValue``): Chrome's `BatterySaverModeManager`
/// tells each child process once per edge (content/child/child_thread_impl.cc `SetBatterySaverMode`).
/// A policy change that keeps both (sleep, power source) is no edge; nor is the policy the app holds
/// when it starts following.
///
/// A new connection has been told nothing (the daemon drops the override of a connection that ended),
/// so each connection is told the current value once.
nonisolated struct DaemonEnergyEdges: Sendable, Equatable {
    /// The app's value as last seen.
    private(set) var value: DaemonEnergyValue
    /// What this connection was told; nil until it is told, and while there is no connection.
    private(set) var told: DaemonEnergyValue?

    init(_ value: DaemonEnergyValue) {
        self.value = value
    }

    /// The app's policy changed: the value to send, or nil when nothing flipped for this connection
    /// (or there is none).
    mutating func observe(_ value: DaemonEnergyValue, connected: Bool) -> DaemonEnergyValue? {
        self.value = value
        return connected ? pending() : nil
    }

    /// A connection came up while the app's value is `value`: the value to tell it.
    mutating func connected(_ value: DaemonEnergyValue) -> DaemonEnergyValue? {
        self.value = value
        told = nil
        return pending()
    }

    /// The connection went away; the next one is told afresh.
    mutating func disconnected() {
        told = nil
    }

    private mutating func pending() -> DaemonEnergyValue? {
        guard told != value else { return nil }
        told = value
        return value
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
        edges = DaemonEnergyEdges(DaemonEnergyValue(source.policy))
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

    nonisolated deinit {
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
        tell(edges.connected(DaemonEnergyValue(policy)), reason: policy.reason)
    }

    /// The app's policy changed: tells the daemon when the saver or "Turn Off for Now" flipped.
    func changed() {
        guard let policy = source?.policy else { return }
        tell(edges.observe(DaemonEnergyValue(policy), connected: connection != nil), reason: policy.reason)
    }

    /// Sends `value` when there is one to send and the daemon serves `energy.set` (an older daemon
    /// does not; it is skipped, not failed); `offForNow` goes only to a daemon that takes it. The pump
    /// sends one at a time and keeps only the newest unsent value, so an on and an off in quick
    /// succession reach the daemon in that order.
    private func tell(_ value: DaemonEnergyValue?, reason: EnergyPolicy.Reason?) {
        guard let value, let store, store.supports(EnergySetRequest.capability) else { return }
        let offForNow = store.supports(EnergySetRequest.ruleCapability) ? value.offForNow : nil
        requests.yield(EnergySetRequest(saver: value.saver, reason: value.saver ? reason?.rawValue : nil,
                                        offForNow: offForNow))
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
