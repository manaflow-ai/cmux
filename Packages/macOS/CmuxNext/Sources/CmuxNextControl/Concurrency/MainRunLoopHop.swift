import CoreFoundation

/// Runs main-actor work on the next turn of the main run loop in the common
/// modes, which include the event-tracking mode. A native menu
/// (`NSMenu.popUp`) or a modal loop runs a nested run loop, often inside a
/// main-queue callout; GCD does not drain the main queue (nor main-actor
/// jobs) again there, but the run loop still runs these blocks. So control
/// requests and frame batches keep moving while a menu is open.
///
/// The seam adapter for main run loop blocks: the main-thread proof for them lives here once.
public struct MainRunLoopHop: Sendable {
    public init() {}

    /// Runs `work` on the main thread at the main run loop's next pass (common modes) and wakes
    /// the run loop for it.
    public func perform(_ work: @escaping @MainActor @Sendable () -> Void) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
            // main-proof: a CFRunLoopGetMain() block runs on the main thread
            MainActor.assumeIsolated { work() }
        }
        CFRunLoopWakeUp(main)
    }
}
