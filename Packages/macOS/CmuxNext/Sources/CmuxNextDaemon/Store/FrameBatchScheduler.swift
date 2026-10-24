import Foundation

/// Runs main-actor work at most once per display frame. The App injects a
/// display-link-backed scheduler; the default runs on the next main-actor
/// turn, which still coalesces every event that arrived in between.
public protocol FrameBatchScheduler: Sendable {
    func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void)
}

public struct NextTurnFrameScheduler: FrameBatchScheduler {
    public init() {}
    public func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
        // task-owner: the frame hop itself; runs once
        Task { @MainActor in work() }
    }
}
