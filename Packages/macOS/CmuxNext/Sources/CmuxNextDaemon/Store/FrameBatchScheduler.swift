import Foundation

/// Runs main-actor work at most once per display frame. The App injects a
/// display-link-backed scheduler (`DaemonService.drainScheduler`), which
/// coalesces every event that arrived in between into one drain.
public protocol FrameBatchScheduler: Sendable {
    func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void)
}
