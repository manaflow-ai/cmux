import CmuxNextCompat
import Foundation

/// Requests one main-actor callback per display frame. The App passes its
/// display-link scheduler (paused while idle); the default hops to the next
/// main run loop turn, which still returns to the run loop between batches.
public protocol ControlFrameSource: Sendable {
    func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void)
    /// Runs `work` as soon as the main thread is free, without waiting for
    /// a display frame: the work queue uses it for the first request after
    /// idle (cx-asb1). Defaults to ``scheduleFrame(_:)``.
    func scheduleSoon(_ work: @escaping @MainActor @Sendable () -> Void)
}

extension ControlFrameSource {
    public func scheduleSoon(_ work: @escaping @MainActor @Sendable () -> Void) {
        scheduleFrame(work)
    }
}

/// Default frame source: one main run loop turn per frame. Each turn
/// returns to the run loop, so input and rendering interleave with queue
/// drains.
public struct MainQueueFrameSource: ControlFrameSource {
    public init() {}

    public func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
        MainRunLoopBlock.perform(work)
    }
}

/// Runs main-actor work on the next turn of the main run loop in the common
/// modes, which include the event-tracking mode. A native menu
/// (`NSMenu.popUp`) or a modal loop runs a nested run loop, often inside a
/// main-queue callout; GCD does not drain the main queue (nor main-actor
/// jobs) again there, but the run loop still runs these blocks. So control
/// requests and frame batches keep moving while a menu is open.
///
/// A forward to CmuxNextCompat's `MainRunLoopBlock`, which holds the one
/// main-thread proof; new code calls `MainRunLoopBlock.perform` directly.
/// It stays only for `FrameBatcher` (CmuxNextDaemonService), whose change is
/// routed to its owner; delete it with that last caller.
public struct MainRunLoopHop: Sendable {
    public init() {}

    public func perform(_ work: @escaping @MainActor @Sendable () -> Void) {
        MainRunLoopBlock.perform(work)
    }
}
