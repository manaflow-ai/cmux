import CmuxNextWakeups
import Foundation

/// libghostty's side of Energy Saver: sends the app's saver state to
/// `ghostty_app_set_energy_saver` on each edge of ``EnergyPolicy/isSaver``, as Chrome's
/// `BatterySaverModeManager` throttles frame sinks only when the mode changes
/// (chrome/browser/performance_manager/user_tuning/battery_saver_mode_manager.cc,
/// `NotifyBatterySaverModeChanged`). Under the saver Ghostty wakes shader and Kitty animations at most
/// every 33 ms, off the display link, and runs scrollback compression at utility QoS; key echo and
/// output frames are unchanged.
///
/// libghostty starts with the saver off, so a saver that stays off makes no call, and a policy change
/// that leaves the saver as it was (power source, sleep, the reason) makes none either. A state the
/// runtime could not take (no app yet) is sent by ``refresh()`` once the app starts.
@MainActor
final class GhosttyEnergySaver {
    /// Sends `on` to libghostty; false when no app runs to take it.
    typealias Apply = @MainActor (_ on: Bool) -> Bool

    /// The owner of the main-thread hop when the policy changes off the main thread.
    nonisolated static let ledgerOwner = "GhosttyEnergySaver"

    private let apply: Apply
    /// The state libghostty has: off until a call it took says otherwise.
    private(set) var sent = false
    private weak var source: EnergyPolicySource?
    private var observation: EnergyPolicyObservation?

    /// - Parameter apply: Sends one state to libghostty (`ghostty_app_set_energy_saver`).
    init(apply: @escaping Apply) {
        self.apply = apply
    }

    /// Sends `source`'s state now when it is on, and on each edge after. A change told off the main
    /// thread runs as a `queue` entry that reads the source's latest policy, so a late hop never sends
    /// an older state.
    func follow(_ source: EnergyPolicySource, queue: MainWakeUpQueue) {
        self.source = source
        observation = source.observe { [weak self] policy in
            // The source tells observers on its writer's thread: the policy driver's, the main actor.
            guard Thread.isMainThread else {
                queue.insert(owner: Self.ledgerOwner, after: .zero) { [weak self] in self?.refresh() }
                return
            }
            // main-proof: guarded by Thread.isMainThread above
            MainActor.assumeIsolated { self?.update(policy) }
        }
        refresh()
    }

    /// Sends the source's state when libghostty does not have it: after an off-main change, and when
    /// the app starts (``GhosttyRuntime/start(with:)``).
    func refresh() {
        guard let source else { return }
        update(source.policy)
    }

    private func update(_ policy: EnergyPolicy) {
        guard policy.isSaver != sent, apply(policy.isSaver) else { return }
        sent = policy.isSaver
    }
}
