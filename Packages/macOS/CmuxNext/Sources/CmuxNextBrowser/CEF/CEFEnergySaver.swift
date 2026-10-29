import CmuxNextWakeups
import Foundation
import os

/// Chromium's side of Energy Saver: sends the app's saver state to the fork's
/// `cmux_cef_set_energy_saver` once when Chromium is ready and then on each edge of
/// ``EnergyPolicy/isSaver``, as Chrome's `BatterySaverModeManager` calls
/// `content::StartThrottlingAllFrameSinks` / `StopThrottlingAllFrameSinks` only when the mode changes
/// (chrome/browser/performance_manager/user_tuning/battery_saver_mode_manager.cc,
/// `NotifyBatterySaverModeChanged`). A policy change that leaves the saver as it was (power source,
/// sleep, the reason) makes no call.
///
/// cmux's own pages (``exemptScheme``) are never throttled: they are the app's UI, which the saver
/// never slows (p14-energy.md, D8).
@MainActor
final class CEFEnergySaver {
    /// Sends `on` to Chromium; true when the fork took it.
    typealias Apply = @MainActor (_ on: Bool) -> Bool

    /// cmux's first-party pages (`cmux-page://`, ``CEFPageSchemes``) keep their full frame rate.
    nonisolated static let exemptScheme = "cmux-page"
    /// The owner of the main-thread hop when the policy changes off the main thread.
    nonisolated static let ledgerOwner = "CEFEnergySaver"

    private let apply: Apply
    /// The state last sent; nil before the first call.
    private(set) var sent: Bool?
    /// The fork took the last call (`debug.energy` `cef.energySaver` `applied`).
    private(set) var isApplied = false
    private var observation: EnergyPolicyObservation?
    /// The followed source, read again by ``resync()``.
    private weak var source: EnergyPolicySource?

    /// - Parameter apply: Sends one state to Chromium (`cmux_shim_set_energy_saver` with ``exemptScheme``).
    init(apply: @escaping Apply) {
        self.apply = apply
    }

    /// Sends `source`'s state now and on each edge after, until ``stop()``. A change told off the main
    /// thread runs as a `queue` entry that reads the source's latest policy, so a late hop never sends
    /// an older state.
    func follow(_ source: EnergyPolicySource, queue: MainWakeUpQueue) {
        self.source = source
        observation = source.observe { [weak self, weak source] policy in
            // The source tells observers on its writer's thread: the policy driver's, the main actor.
            guard Thread.isMainThread else {
                queue.insert(owner: Self.ledgerOwner, after: .zero) { [weak self, weak source] in
                    guard let source else { return }
                    self?.update(source.policy)
                }
                return
            }
            // main-proof: guarded by Thread.isMainThread above
            MainActor.assumeIsolated { self?.update(policy) }
        }
        update(source.policy)
    }

    /// Sends `policy`'s saver state when it differs from the state last sent.
    func update(_ policy: EnergyPolicy) {
        guard policy.isSaver != sent else { return }
        sent = policy.isSaver
        isApplied = apply(policy.isSaver)
    }

    /// Sends the source's state again, edge or not: a new Chromium (a restarted host) has not had it, and
    /// an edge while no Chromium ran reached nobody.
    func resync() {
        guard let source else { return }
        sent = nil
        update(source.policy)
    }
}

extension CEFEnergySaver {
    /// `runtime`'s saver, called once Chromium is first ready (each later ready calls ``resync()``): it
    /// sends the policy of `runtime.wakeUps` (the scheduler's one source, `MainWorkScheduler.energy`) now
    /// and on each edge, through `cmux_shim_set_energy_saver` with ``exemptScheme``. Nil below
    /// ``CEFForkFeatures/energySaverForkAPI``: no call at all. Once quit begins to stop Chromium it makes no more calls.
    static func following(_ runtime: CEFRuntime) -> CEFEnergySaver? {
        guard runtime.forkFeatures.energySaver else { return nil }
        let saver = CEFEnergySaver { [weak runtime] on in
            guard let runtime, runtime.state == .ready, runtime.shutdownSequence == nil, let shim = runtime.shim else { return false }
            return shim.setEnergySaver(on ? 1 : 0, CEFEnergySaver.exemptScheme) == 1
        }
        saver.follow(runtime.wakeUps.energy, queue: runtime.wakeUps)
        runtime.logger.notice("CEF energy saver: \(saver.isApplied ? "applied" : "refused", privacy: .public) on=\(saver.sent == true, privacy: .public)")
        return saver
    }

    /// `runtime`'s Chromium took the app's last saver state: false before the ready hooks, below the fork
    /// API, or when the fork refused it.
    static func applied(by runtime: CEFRuntime) -> Bool { runtime.energySaver?.isApplied ?? false }
}

extension CEFEngine {
    /// Chromium took the app's last Energy Saver state (`debug.energy` `cef.energySaver`, ``CEFEnergySaver``).
    public var energySaverApplied: Bool { CEFEnergySaver.applied(by: .shared) }
}
