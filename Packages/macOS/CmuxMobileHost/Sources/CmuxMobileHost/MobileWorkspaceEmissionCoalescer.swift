import Foundation

/// Caps expensive mobile-workspace emissions while retaining the latest state.
///
/// A leading request that publishes state runs synchronously, then opens the
/// bounded window. No-op requests leave the leading edge available. Requests
/// during an open window replace one pending trailing action, so a continuous
/// burst emits at most once per window and the final authoritative state is
/// never lost.
@MainActor
public final class MobileWorkspaceEmissionCoalescer {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias Action = @MainActor () -> Bool

    private let window: Duration
    private let sleep: Sleep
    private var pendingAction: Action?
    private var windowTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(
        window: Duration,
        sleep: @escaping Sleep
    ) {
        self.window = max(.zero, window)
        self.sleep = sleep
    }

    public func request(_ action: @escaping Action) {
        guard windowTask != nil else {
            guard action() else { return }
            startWindow()
            return
        }
        pendingAction = action
    }

    public func cancel() {
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
        guard action() else { return }
        startWindow()
    }
}
