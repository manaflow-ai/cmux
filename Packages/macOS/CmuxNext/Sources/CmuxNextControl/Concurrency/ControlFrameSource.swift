import Foundation

/// Requests one main-actor callback per display frame. The App passes its
/// display-link scheduler (paused while idle); the default hops to the next
/// main run loop turn, which still returns to the run loop between batches.
public protocol ControlFrameSource: Sendable {
    func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void)
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
