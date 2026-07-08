import Foundation

@MainActor
final class CanvasMinimapAutoHideScheduler {
    private let clock: CanvasMinimapAutoHideClock
    private let delay: Duration
    private var deadline: Duration?
    private var task: Task<Void, Never>?
    var hasPendingHide: Bool {
        deadline != nil || task != nil
    }

    init<C: Clock & Sendable>(clock: C, delay: Duration = .seconds(3)) where C.Duration == Duration {
        self.clock = CanvasMinimapAutoHideClock(clock)
        self.delay = delay
    }

    func schedule(_ action: @escaping @MainActor () -> Void) {
        deadline = clock.now() + delay
        guard task == nil else { return }

        task = Task { @MainActor [weak self] in
            while true {
                guard let self else { return }
                guard let deadline else {
                    task = nil
                    return
                }

                let remaining = deadline - clock.now()
                if remaining <= .zero {
                    self.deadline = nil
                    task = nil
                    action()
                    return
                }

                do {
                    try await clock.sleep(remaining)
                } catch {
                    return
                }
            }
        }
    }

    func cancel() {
        deadline = nil
        task?.cancel()
        task = nil
    }
}
