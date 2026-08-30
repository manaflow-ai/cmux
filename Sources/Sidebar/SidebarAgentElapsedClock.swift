import Foundation
import CmuxFoundation
import Observation

/// Main-actor registry for one demand-owned elapsed scheduler.
/// Targets are weak and limited to realized elapsed labels plus the AppKit
/// table controller; a tick never scans the sidebar's full row collection.
@MainActor
@Observable
final class SidebarAgentElapsedClock {
    // Registration happens from realized-row AppKit callbacks. Keep this
    // demand bit ignored so those callbacks never invalidate the lazy parent.
    @ObservationIgnored
    private var targets: [ObjectIdentifier: SidebarAgentElapsedClockWeakTarget] = [:]
    @ObservationIgnored
    private let displayCache = SidebarAgentActivityDisplayCache()
    @ObservationIgnored
    private let scheduler: MainActorDeferredActionScheduler

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.scheduler = MainActorDeferredActionScheduler(clock: clock)
    }

    /// Diagnostic demand state for tests and owner introspection. Registration
    /// is intentionally non-observed by the lazy sidebar parent.
    @ObservationIgnored
    var hasTargets: Bool { !targets.isEmpty }

    /// Whether the demand-owned scheduler is currently armed.
    @ObservationIgnored
    var isTickerRunning: Bool { scheduler.isScheduled }

    var actions: SidebarAgentElapsedClockActions {
        let cache = displayCache
        return SidebarAgentElapsedClockActions(
            identity: ObjectIdentifier(self),
            register: { [weak self] target in self?.register(target) },
            unregister: { [weak self] target in self?.unregister(target) },
            displayPayload: { activity, now in
                cache.payload(for: activity, at: now)
            }
        )
    }

    private func register(_ target: any SidebarAgentElapsedClockTarget) {
        targets[ObjectIdentifier(target)] = SidebarAgentElapsedClockWeakTarget(value: target)
        startTickerIfNeeded()
    }

    private func unregister(_ target: any SidebarAgentElapsedClockTarget) {
        targets.removeValue(forKey: ObjectIdentifier(target))
        stopTickerIfUnused()
    }

    func tick(at now: Date) {
        guard !targets.isEmpty else { return }
        var releasedTargets: [ObjectIdentifier] = []
        for (identifier, target) in targets {
            guard let value = target.value else {
                releasedTargets.append(identifier)
                continue
            }
            value.sidebarAgentElapsedClockDidTick(at: now)
        }
        for identifier in releasedTargets {
            targets.removeValue(forKey: identifier)
        }
        stopTickerIfUnused()
    }

    private func startTickerIfNeeded() {
        guard !targets.isEmpty, !scheduler.isScheduled else { return }
        scheduleNextTick()
    }

    private func stopTickerIfUnused() {
        guard targets.isEmpty else { return }
        scheduler.cancel()
    }

    private func scheduleNextTick() {
        guard !targets.isEmpty else {
            scheduler.cancel()
            return
        }
        scheduler.schedule(after: .seconds(1)) { [weak self] in
            guard let self, !self.targets.isEmpty else { return }
            self.tick(at: Date())
            self.scheduleNextTick()
        }
    }
}
