public import CmuxNextWakeups

/// The App's consumers that take the energy policy as a value instead of reading an
/// ``EnergyPolicySource``: the local daemon (`energy.set`, which also reaches acpmux) and KeepAwake
/// (on battery). The composition root conforms with one-line forwards (`AppServices+EnergyHost.swift`).
@MainActor
public protocol EnergyHost: AnyObject {
    /// The policy changed (any field: saver, reason, suspend, screen sleep, power source).
    func energyPolicyDidChange(_ policy: EnergyPolicy)
    /// The Mac moved between battery and adapter power.
    func onBatteryDidChange(_ onBattery: Bool)
}

/// Tells an ``EnergyHost`` the policy now and after each change; the battery edge only when it moves.
/// The source's observers run on its writer's thread (the main actor's `EnergyMonitor`), so delivery is
/// inline; a write from another thread reaches the host on the main queue's next turn, in order.
@MainActor
public final class EnergyHostLink {
    private weak var host: (any EnergyHost)?
    private var onBattery: Bool
    private var observation: EnergyPolicyObservation?

    /// Starts forwarding `source` to `host` (held weakly) and tells it the current policy at once.
    public init(source: EnergyPolicySource, host: any EnergyHost) {
        let policy = source.policy
        self.host = host
        onBattery = policy.onBattery
        host.energyPolicyDidChange(policy)
        host.onBatteryDidChange(policy.onBattery)
        observation = source.observe { [weak self] policy in
            MainDelivery().run { [weak self] in self?.deliver(policy) }
        }
    }

    /// Stops forwarding; later changes reach nobody.
    public func cancel() {
        observation?.cancel()
        observation = nil
    }

    private func deliver(_ policy: EnergyPolicy) {
        guard observation != nil, let host else { return }
        host.energyPolicyDidChange(policy)
        guard policy.onBattery != onBattery else { return }
        onBattery = policy.onBattery
        host.onBatteryDidChange(policy.onBattery)
    }
}
