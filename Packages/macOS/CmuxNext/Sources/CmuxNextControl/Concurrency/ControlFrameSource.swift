import Foundation
public import CmuxNextWakeups

/// Requests one main-actor callback per display frame. The App passes its
/// display-link scheduler (paused while idle); the default hops to the next
/// main run loop turn, which still returns to the run loop between batches.
public protocol ControlFrameSource: Sendable {
    func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void)
    /// Runs `work` as soon as the main thread is free, without waiting for
    /// a display frame: the work queue uses it for the first request after
    /// idle (cx-asb1). Defaults to ``scheduleFrame(_:)``.
    func scheduleSoon(_ work: @escaping @MainActor @Sendable () -> Void)
    /// Queues `work` for the next display frame from main-actor code, typically a drain that left
    /// work and re-arms itself inside the frame it runs in. The app's batcher appends it to its
    /// frame queue at once, so the queue reports work left and its display link keeps running; a
    /// hop through the run loop would land after the tick, find the queue empty, and tear the link
    /// down and rebuild it every frame. Defaults to ``scheduleFrame(_:)``.
    @MainActor func scheduleFrameFromMain(_ work: @escaping @MainActor @Sendable () -> Void)
    /// The app's main-thread budget its frames draw on (``MainFrameBudget``): the work queue
    /// charges each request to the automation class and stops a drain when the class may not run.
    /// Nil (the default): the queue keeps its own `frameBudget`.
    @MainActor var mainFrameBudget: MainFrameBudget? { get }
    /// That budget's board, readable off the main actor: the queue interns each request's method
    /// there before queuing it, and counts queued injected input there, so batches yield to it.
    /// Nil by default.
    var mainTaskBoard: MainTaskBoard? { get }
}

extension ControlFrameSource {
    public func scheduleSoon(_ work: @escaping @MainActor @Sendable () -> Void) {
        scheduleFrame(work)
    }

    @MainActor public func scheduleFrameFromMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        scheduleFrame(work)
    }

    @MainActor public var mainFrameBudget: MainFrameBudget? { nil }
    public var mainTaskBoard: MainTaskBoard? { nil }
}

/// Default frame source: one main run loop turn per frame. Each turn
/// returns to the run loop, so input and rendering interleave with queue
/// drains.
public struct MainQueueFrameSource: ControlFrameSource {
    public init() {}

    public func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
        MainRunLoopHop().perform(work)
    }
}

/// Runs main-actor work on the next turn of the main run loop in the common
/// modes, which include the event-tracking mode. A native menu
/// (`NSMenu.popUp`) or a modal loop runs a nested run loop, often inside a
/// main-queue callout; GCD does not drain the main queue (nor main-actor
/// jobs) again there, but the run loop still runs these blocks. So control
/// requests and frame batches keep moving while a menu is open.
public struct MainRunLoopHop: Sendable {
    public init() {}

    public func perform(_ work: @escaping @MainActor @Sendable () -> Void) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
            // main-proof: a CFRunLoopGetMain() block runs on the main thread
            MainActor.assumeIsolated { work() }
        }
        CFRunLoopWakeUp(main)
    }
}
