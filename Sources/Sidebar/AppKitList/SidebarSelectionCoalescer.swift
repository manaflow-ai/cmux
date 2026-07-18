import AppKit
import QuartzCore

/// Coalesces rapid plain-click workspace selections to the latest request.
///
/// A selection commit re-renders the container and swaps the terminal
/// content (~tens of ms); without coalescing, a burst of clicks queues one
/// full commit per click and later selections feel progressively slower.
/// Leading edge applies immediately (single clicks keep their latency);
/// clicks landing inside the window replace the pending request and one
/// trailing fire applies only the newest. The row's optimistic mouse-up
/// highlight still tracks every completed click instantly.
@MainActor
final class SidebarSelectionCoalescer {
    private var pendingApply: (() -> Void)?
    private var trailingTask: Task<Void, Never>?
    private var lastApplied: CFTimeInterval = 0
    private let window: TimeInterval
    private let clock: any Clock<Duration>

    init(window: TimeInterval = 0.1, clock: any Clock<Duration> = ContinuousClock()) {
        self.window = window
        self.clock = clock
    }

    func request(_ apply: @escaping @MainActor () -> Void) {
        let now = CACurrentMediaTime()
        if trailingTask == nil, now - lastApplied >= window {
            lastApplied = now
            apply()
            return
        }
        pendingApply = apply
        guard trailingTask == nil else { return }
        let delay = max(0, window - (now - lastApplied))
        // Injected-Clock sleep with cancellation wired to `cancel()`, per the
        // bounded-delay policy (no raw Task.sleep in production paths).
        trailingTask = Task { [weak self, clock] in
            try? await clock.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.trailingTask = nil
            self.lastApplied = CACurrentMediaTime()
            let apply = self.pendingApply
            self.pendingApply = nil
            apply?()
        }
    }

    /// Drops any pending request. Used before selection paths that must not
    /// be reordered (modifier clicks mutate the multi-selection set).
    func cancel() {
        trailingTask?.cancel()
        trailingTask = nil
        pendingApply = nil
    }
}
