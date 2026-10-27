/// Hands each change of an ``EnergyPolicySource`` to a main-actor closure, until cancelled or
/// released: the seam adapter for main-actor consumers (BrowserHibernation, WebKitEngine) that
/// follow the app's Energy Saver policy.
public final class MainActorEnergyObservation: Sendable {
    private let observation: EnergyPolicyObservation

    /// Calls `onChange` after each change of `energy`'s policy.
    ///
    /// - Parameters:
    ///   - energy: The app's one policy source (`MainWorkScheduler.energy`), written on the main actor by
    ///     its one writer, `EnergyPolicyDriver`.
    ///   - onChange: Runs on the main actor with the new policy.
    public init(_ energy: EnergyPolicySource, onChange: @escaping @MainActor @Sendable (EnergyPolicy) -> Void) {
        observation = energy.observe { policy in
            // main-proof: observers run on the writer's thread, and the source's one writer is the @MainActor EnergyPolicyDriver
            MainActor.assumeIsolated { onChange(policy) }
        }
    }

    /// Stops the calls; later calls do nothing.
    public func cancel() { observation.cancel() }
}
