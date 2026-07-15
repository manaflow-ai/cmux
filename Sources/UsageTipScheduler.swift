import Foundation

@MainActor
struct UsageTipScheduler {
    typealias Action = @MainActor @Sendable () -> Void
    typealias Cancellation = @MainActor () -> Void
    typealias Schedule = @MainActor (TimeInterval, @escaping Action) -> Cancellation

    private let scheduleAction: Schedule

    init(
        scheduleAction: @escaping Schedule = { interval, action in
            // One-shot timers model intentional presentation deadlines; tests inject this seam.
            let timer = Timer(timeInterval: max(0, interval), repeats: false) { _ in
                MainActor.assumeIsolated {
                    action()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            return {
                timer.invalidate()
            }
        }
    ) {
        self.scheduleAction = scheduleAction
    }

    func schedule(after interval: TimeInterval, action: @escaping Action) -> Cancellation {
        scheduleAction(interval, action)
    }
}
