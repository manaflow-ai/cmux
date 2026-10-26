public import CmuxNextWakeups

/// The App's consumers that take the energy policy as a value instead of reading an
/// ``EnergyPolicySource``: the local daemon (`energy.set`, which also reaches acpmux) and KeepAwake
/// (on battery). The composition root conforms with one-line forwards (`AppServices+EnergyHost.swift`).
@MainActor
public protocol EnergyHost: AnyObject {
    /// The saver turned on or off, or its reason changed. Other fields (screen sleep, suspend,
    /// power source) do not call this, so a screen-sleep edge costs the daemon no round trip.
    func energySaverDidChange(_ policy: EnergyPolicy)
    /// The Mac moved between battery and adapter power.
    func onBatteryDidChange(_ onBattery: Bool)
}

/// Tells an ``EnergyHost`` the policy now, then each saver edge and each battery edge.
///
/// Any thread may write the source. Each change only asks for a delivery on the main actor, and a
/// delivery reads the source's value at that moment. So a write from another thread that reaches the
/// main queue after a later main-thread write delivers nothing stale: the host always ends on the
/// source's latest value.
@MainActor
public final class EnergyHostLink {
    private let delivery: Delivery
    private let observation: EnergyPolicyObservation

    /// Starts forwarding `source` to `host` (held weakly) and tells it the current policy at once.
    ///
    /// - Parameter schedule: Runs a delivery on the main actor: inline on the main thread, on the main
    ///   queue's next turn from another thread (``MainDelivery``). Tests pass their own.
    public init(
        source: EnergyPolicySource,
        host: any EnergyHost,
        schedule: @escaping @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { MainDelivery().run($0) }
    ) {
        let delivery = Delivery(source: source, host: host)
        self.delivery = delivery
        observation = source.observe { [weak delivery] _ in
            schedule { [weak delivery] in delivery?.deliverLatest() }
        }
        delivery.deliverLatest()
    }

    deinit {
        observation.cancel()
    }

    /// Stops forwarding; later changes reach nobody.
    public func cancel() {
        observation.cancel()
        delivery.isCancelled = true
    }
}

@MainActor
private final class Delivery {
    let source: EnergyPolicySource
    weak var host: (any EnergyHost)?
    var isCancelled = false
    private var delivered: EnergyPolicy?

    init(source: EnergyPolicySource, host: any EnergyHost) {
        self.source = source
        self.host = host
    }

    func deliverLatest() {
        guard !isCancelled, let host else { return }
        let policy = source.policy
        let last = delivered
        delivered = policy  // before the host runs: a write it makes delivers against this value
        if last == nil || last?.isSaver != policy.isSaver || last?.reason != policy.reason {
            host.energySaverDidChange(policy)
        }
        if last?.onBattery != policy.onBattery {
            host.onBatteryDidChange(policy.onBattery)
        }
    }
}
