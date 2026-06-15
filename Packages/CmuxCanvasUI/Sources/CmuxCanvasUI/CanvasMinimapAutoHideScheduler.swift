import Foundation

@MainActor
final class CanvasMinimapAutoHideScheduler {
    private let clock: any Clock<Duration>
    private let delaySeconds: TimeInterval
    private var deadline: Date?
    private var task: Task<Void, Never>?

    init(clock: any Clock<Duration>, delaySeconds: TimeInterval = 3) {
        self.clock = clock
        self.delaySeconds = delaySeconds
    }

    func schedule(_ action: @escaping @MainActor () -> Void) {
        deadline = Date().addingTimeInterval(delaySeconds)
        guard task == nil else { return }

        task = Task { @MainActor [weak self] in
            while true {
                guard let self else { return }
                guard let deadline else {
                    task = nil
                    return
                }

                let remaining = deadline.timeIntervalSince(Date())
                if remaining <= 0 {
                    self.deadline = nil
                    task = nil
                    action()
                    return
                }

                do {
                    try await clock.sleep(for: Self.duration(for: remaining))
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

    private static func duration(for interval: TimeInterval) -> Duration {
        .milliseconds(max(1, Int64((interval * 1000).rounded(.up))))
    }
}
