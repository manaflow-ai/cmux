import Foundation
public import CmuxNextWakeups

/// Runs main-actor work at most once per display frame. The App injects a
/// display-link-backed scheduler; the default runs on the next main-actor
/// turn, which still coalesces every event that arrived in between.
public protocol FrameBatchScheduler: Sendable {
    func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void)
    /// The app's main-thread budget the batches draw on (``MainFrameBudget``): the store applies a
    /// large batch in slices while the visible class may run and keeps the rest for the next
    /// frame. Nil (the default): the whole batch applies at once.
    @MainActor var mainFrameBudget: MainFrameBudget? { get }
}

extension FrameBatchScheduler {
    @MainActor public var mainFrameBudget: MainFrameBudget? { nil }
}

public struct NextTurnFrameScheduler: FrameBatchScheduler {
    public init() {}
    public func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
        // task-owner: the frame hop itself; runs once
        Task { @MainActor in work() }
    }
}
