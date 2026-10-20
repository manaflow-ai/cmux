import Foundation

/// Watches per-panel simulator stream liveness on the phone.
///
/// While a stream session is active, the Mac emits `simulator.state` on a
/// fixed cadence (capability `simulator.keepalive.v1`), so a healthy session
/// produces events even when the Simulator screen is static. Each armed panel
/// keeps an activity counter that frame and state events bump; a watcher task
/// samples the counter every `threshold` and fires `onStale` when an interval
/// passes with no activity. The watcher keeps sampling after a fire, so a
/// recovery attempt that itself dies silently retries one threshold later.
///
/// Counters instead of task re-arming keep the frame path cheap: a 60 fps
/// stream bumps an integer rather than cancelling and respawning a task per
/// frame.
@MainActor
final class MobileSimulatorStreamStalenessMonitor {
    private let clock: any Clock<Duration>
    private let threshold: Duration
    private let onStale: @MainActor (String) -> Void
    private var watchersByPanel: [String: Task<Void, Never>] = [:]
    private var activityCountersByPanel: [String: UInt64] = [:]

    init(
        clock: any Clock<Duration>,
        threshold: Duration,
        onStale: @escaping @MainActor (String) -> Void
    ) {
        self.clock = clock
        self.threshold = threshold
        self.onStale = onStale
    }

    /// Starts watching a panel. Idempotent: an armed panel keeps its existing
    /// watcher and activity history.
    func arm(panelID: String) {
        guard watchersByPanel[panelID] == nil else { return }
        activityCountersByPanel[panelID] = 0
        watchersByPanel[panelID] = Task { @MainActor [weak self] in
            await self?.watch(panelID: panelID)
        }
    }

    /// Records liveness for a panel. Ignored for unarmed panels so passive
    /// state events for streams this phone never started don't accumulate.
    func recordActivity(panelID: String) {
        guard watchersByPanel[panelID] != nil else { return }
        activityCountersByPanel[panelID, default: 0] &+= 1
    }

    func disarm(panelID: String) {
        watchersByPanel.removeValue(forKey: panelID)?.cancel()
        activityCountersByPanel.removeValue(forKey: panelID)
    }

    func disarmAll() {
        for task in watchersByPanel.values {
            task.cancel()
        }
        watchersByPanel.removeAll()
        activityCountersByPanel.removeAll()
    }

    private func watch(panelID: String) async {
        while !Task.isCancelled {
            let snapshot = activityCountersByPanel[panelID]
            do {
                try await clock.sleep(for: threshold)
            } catch {
                return
            }
            guard !Task.isCancelled, watchersByPanel[panelID] != nil else { return }
            if let snapshot, activityCountersByPanel[panelID] == snapshot {
                onStale(panelID)
            }
        }
    }
}
