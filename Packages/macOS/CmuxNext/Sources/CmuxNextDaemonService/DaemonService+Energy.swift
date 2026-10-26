import CmuxNextDaemon
public import CmuxNextWakeups

/// `energy.set` (cmux-tui-core server/energy_op.rs, p14-energy-033): the app's Energy Saver, an
/// override of the daemon's own reading. `reason` is the policy's ``EnergyPolicy/Reason`` and goes
/// only with `saver: true`; nil is left out of the line.
nonisolated struct EnergySetRequest: DaemonRequest {
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
/// A new connection has been told nothing, and the daemon may hold an override from an earlier app
/// run, so each connection is told the current value once.
nonisolated struct DaemonEnergyEdges: Sendable, Equatable {
    /// The app's saver as last seen.
    private(set) var saver: Bool
    /// What this connection was told; nil until it is told.
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

    private mutating func pending() -> Bool? {
        guard told != saver else { return nil }
        told = saver
        return saver
    }
}

/// Tells one local daemon each edge of the app's Energy Saver: it observes the app's
/// ``EnergyPolicySource`` and sends `energy.set` through its ``DaemonService`` (held weakly; the service
/// owns this). The source is the composition root's and is held weakly too.
final class DaemonEnergyFollow {
    private weak var source: EnergyPolicySource?
    private weak var service: DaemonService?
    private var observation: MainActorEnergyObservation?
    private(set) var edges: DaemonEnergyEdges
    /// The latest `energy.set` not yet sent, and the one push that sends it.
    private var pending: EnergySetRequest?
    private var push: Task<Void, Never>?

    init(_ source: EnergyPolicySource, service: DaemonService) {
        self.source = source
        self.service = service
        edges = DaemonEnergyEdges(saver: source.policy.isSaver)
        observation = MainActorEnergyObservation(source) { [weak self] _ in self?.changed() }
        if service.isLive { connected() }
    }

    /// A connection came up (`didConnect`, or `init` on a live one): tells it the saver the app holds now.
    func connected() {
        guard let policy = source?.policy else { return }
        tell(edges.connected(saver: policy.isSaver), reason: policy.reason)
    }

    /// The app's policy changed: tells the daemon when the saver flipped.
    func changed() {
        guard let policy = source?.policy, let service else { return }
        tell(edges.observe(saver: policy.isSaver, connected: service.isLive), reason: policy.reason)
    }

    /// Sends `saver` when there is one to send and the daemon serves `energy.set` (an older daemon
    /// does not; it is skipped, not failed). One push runs at a time and sends the latest value, so
    /// an on and an off in quick succession reach the daemon in that order.
    private func tell(_ saver: Bool?, reason: EnergyPolicy.Reason?) {
        guard let saver, let service, service.supports(EnergySetRequest.capability) else { return }
        pending = EnergySetRequest(saver: saver, reason: saver ? reason?.rawValue : nil)
        guard push == nil else { return }
        push = Task { [weak self] in
            while let self, let request = pending, let service = self.service {
                pending = nil
                await service.run("energy.set") { _ = try await $0.request(request) }
            }
            self?.push = nil
        }
    }
}

extension DaemonService {
    /// Tells the local daemon each Energy Saver edge (`energy.set`); a Cloud machine's daemon does
    /// not follow this Mac's power. The composition root calls it once with ``MainWorkScheduler/energy``.
    public func follow(_ energy: EnergyPolicySource) {
        if isLocal { energyFollow = DaemonEnergyFollow(energy, service: self) }
    }
}
