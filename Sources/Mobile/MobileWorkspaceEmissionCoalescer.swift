import Foundation

/// Caps expensive mobile-workspace emissions while retaining the latest state.
///
/// The leading request runs synchronously. Requests during the bounded window
/// replace one pending trailing action, so a continuous burst emits at most once
/// per window and the final authoritative state is never lost.
@MainActor
final class MobileWorkspaceEmissionCoalescer {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let window: Duration
    private let sleep: Sleep
    private var pendingAction: (@MainActor () -> Void)?
    private var windowTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(
        window: Duration,
        sleep: @escaping Sleep
    ) {
        self.window = max(.zero, window)
        self.sleep = sleep
    }

    func request(_ action: @escaping @MainActor () -> Void) {
        guard windowTask != nil else {
            startWindow()
            action()
            return
        }
        pendingAction = action
    }

    func cancel() {
        generation &+= 1
        windowTask?.cancel()
        windowTask = nil
        pendingAction = nil
    }

    deinit {
        windowTask?.cancel()
    }

    private func startWindow() {
        generation &+= 1
        let scheduledGeneration = generation
        let sleep = sleep
        let window = window
        windowTask = Task { @MainActor [weak self, sleep, window] in
            let completed: Bool
            do {
                try await sleep(window)
                completed = !Task.isCancelled
            } catch {
                completed = false
            }
            self?.finishWindow(
                generation: scheduledGeneration,
                completed: completed
            )
        }
    }

    private func finishWindow(
        generation scheduledGeneration: UInt64,
        completed: Bool
    ) {
        guard generation == scheduledGeneration else { return }
        windowTask = nil
        guard completed else {
            pendingAction = nil
            return
        }
        guard let action = pendingAction else { return }
        pendingAction = nil
        startWindow()
        action()
    }
}
