import Foundation

/// Requests one main-actor callback per display frame. The App passes its
/// display-link scheduler (paused while idle); the default hops to the next
/// main-queue turn, which still returns to the run loop between batches.
public protocol ControlFrameSource: Sendable {
    func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void)
}

/// Default frame source: one main-queue turn per frame. Each turn returns
/// to the run loop, so input and rendering interleave with queue drains.
public struct MainQueueFrameSource: ControlFrameSource {
    public init() {}

    public func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }
}
