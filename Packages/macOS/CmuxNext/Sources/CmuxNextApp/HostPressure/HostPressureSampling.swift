import CmuxNextCompat
import CmuxNextWakeups

/// When a window's host pressure indicator samples the host (cmux#22662: a new dev
/// surface ships off). It samples only while the feature `hostPressure` (resolved at
/// launch; Debug Settings `hostPressure.enabled` is its local override) is on and its window
/// can be seen: the window's node in the visibility tree is visible (in a window, not
/// minimized, not fully occluded, cmux not hidden, the displays awake). Everything else
/// (feature off, hidden, minimized, occluded, closed) means no subscription, so no service,
/// no monitor, no 15 s timer and no reads.
@MainActor struct HostPressureSampling: Equatable {
    var enabled: Bool
    var windowVisible: Bool

    var samples: Bool { enabled && windowVisible }
}

/// One window's subscription to the app's `HostPressureService`. `cancel()` ends it at once;
/// a subscription released without one (its indicator freed off the main thread, where the
/// indicator's deinit cannot touch main-actor state) ends on the main actor instead, so a
/// window never leaves a subscriber behind that would keep the monitor's timer running.
nonisolated final class HostPressureSubscription: Sendable {
    let service: HostPressureService
    /// Where a subscription released without ``cancel()`` posts its unsubscribe.
    private let mainWork: MainWorkScheduler
    private let live = Mutex(true)

    @MainActor init(_ service: HostPressureService) {
        self.service = service
        mainWork = service.mainWork
        service.subscribe()
    }

    /// Whether this call ended it (the first `cancel()` or the deinit).
    private func end() -> Bool {
        live.withLock { live in
            defer { live = false }
            return live
        }
    }

    @MainActor func cancel() {
        if end() { service.unsubscribe() }
    }

    deinit {
        guard end() else { return }
        let service = service
        // One background task (nobody sees the monitor stop) that ends a subscription released without cancel().
        mainWork.postFromAnyThread(.background, owner: "HostPressureSubscription.release") { service.unsubscribe() }
    }
}
