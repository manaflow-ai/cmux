import AppKit
import os

nonisolated final class TerminalSelectionAccessibilityIngressGate: @unchecked Sendable {
    nonisolated enum DrainDecision: Equatable, Sendable {
        case reschedule(TimeInterval)
        case post
    }

    private nonisolated struct State {
        var hasPendingMainActorHop = false
        var latestRequestTime: TimeInterval = 0
    }

    private nonisolated let state = OSAllocatedUnfairLock(initialState: State())

    /// Records an event and returns whether the caller owns the one permitted
    /// main-actor hop for the current burst.
    nonisolated func registerRequest(at timestamp: TimeInterval) -> Bool {
        state.withLock { state in
            state.latestRequestTime = timestamp
            guard !state.hasPendingMainActorHop else { return false }
            state.hasPendingMainActorHop = true
            return true
        }
    }

    /// Keeps the hop claimed until the latest event has been quiet for the
    /// debounce interval. Releasing only at `.post` prevents later events in
    /// the same burst from creating more main-actor work.
    nonisolated func drainDecision(
        at timestamp: TimeInterval,
        debounceInterval: TimeInterval
    ) -> DrainDecision {
        state.withLock { state in
            let elapsed = max(0, timestamp - state.latestRequestTime)
            let remaining = debounceInterval - elapsed
            if remaining > 0 {
                return .reschedule(remaining)
            }

            state.hasPendingMainActorHop = false
            return .post
        }
    }
}

@MainActor
final class TerminalSelectionAccessibilityNotifier {
    private static let debounceInterval: TimeInterval = 0.1

    nonisolated let ingressGate = TerminalSelectionAccessibilityIngressGate()
    private var debounceTimer: Timer?
    private weak var element: NSView?

    nonisolated init() {}

    func attach(element: NSView) {
        self.element = element
    }

    /// Safe for Ghostty's renderer callback thread. A burst owns one pending
    /// main-actor hop, regardless of how many selection events arrive before
    /// the UI can process them.
    nonisolated func request() {
        let now = ProcessInfo.processInfo.systemUptime
        guard ingressGate.registerRequest(at: now) else { return }

        Task { @MainActor [weak self] in
            self?.drainWhenQuiet()
        }
    }

    private func drainWhenQuiet() {
        debounceTimer?.invalidate()

        switch ingressGate.drainDecision(
            at: ProcessInfo.processInfo.systemUptime,
            debounceInterval: Self.debounceInterval
        ) {
        case .post:
            self.debounceTimer = nil
            guard let element else { return }
            NSAccessibility.post(element: element, notification: .selectedTextChanged)

        case .reschedule(let delay):
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] timer in
                // This timer is registered only on RunLoop.main below.
                MainActor.assumeIsolated {
                    guard let self, self.debounceTimer === timer else { return }
                    self.drainWhenQuiet()
                }
            }
            debounceTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    deinit {
        debounceTimer?.invalidate()
    }
}
