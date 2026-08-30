import Foundation
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
    /// Monotonic clock used only while a realized target needs elapsed text.
    /// Keeping this injected makes the scheduler cancellable and testable,
    /// while avoiding a permanently mounted SwiftUI timeline.
    @ObservationIgnored
    private let clock: any Clock<Duration>
    @ObservationIgnored
    private var tickerTask: Task<Void, Never>?

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    deinit {
        tickerTask?.cancel()
    }

    /// Diagnostic demand state for tests and owner introspection. Registration
    /// is intentionally non-observed by the lazy sidebar parent.
    @ObservationIgnored
    var hasTargets: Bool { !targets.isEmpty }

    /// Whether the demand-owned scheduler is currently armed.
    @ObservationIgnored
    var isTickerRunning: Bool { tickerTask != nil }

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
        guard !targets.isEmpty, tickerTask == nil else { return }
        let clock = clock
        tickerTask = Task { @MainActor [weak self, clock] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled, !self.targets.isEmpty else {
                    return
                }
                self.tick(at: Date())
            }
        }
    }

    private func stopTickerIfUnused() {
        guard targets.isEmpty else { return }
        tickerTask?.cancel()
        tickerTask = nil
    }
}
