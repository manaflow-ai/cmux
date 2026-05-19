import Foundation

public struct VNCHelperRestartPolicy: Equatable, Sendable {
    public var maxRestarts: Int
    public var windowSeconds: TimeInterval

    public init(maxRestarts: Int = 3, windowSeconds: TimeInterval = 60) {
        self.maxRestarts = maxRestarts
        self.windowSeconds = windowSeconds
    }

    public func canRestart(previousRestartDates: [Date], now: Date) -> Bool {
        restartsWithinWindow(previousRestartDates: previousRestartDates, now: now).count < maxRestarts
    }

    public func recordRestart(previousRestartDates: [Date], now: Date) -> [Date] {
        restartsWithinWindow(previousRestartDates: previousRestartDates, now: now) + [now]
    }

    private func restartsWithinWindow(previousRestartDates: [Date], now: Date) -> [Date] {
        previousRestartDates.filter {
            let interval = now.timeIntervalSince($0)
            return interval >= 0 && interval <= windowSeconds
        }
    }
}
