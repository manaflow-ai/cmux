import CoreFoundation

/// Runs `work` once, on the main run loop's next pass to the point where it
/// waits for events, after AppKit displayed its windows and Core Animation
/// committed the frame they drew: work that frame does not show starts only
/// once the frame is on its way to the screen.
///
/// A main-actor `Task` would run earlier: the run loop drains the main queue
/// before that point, so the work would delay the frame it tries to follow.
func scheduleAfterFrameCommit(_ work: @escaping @MainActor () -> Void) {
    let main = CFRunLoopGetMain()
    // A before-waiting run loop observer: the frame commit point has no async-native signal.
    // Ordered last (`CFIndex.max`), after AppKit's display and Core Animation's commit
    // observers; non-repeating, so the run loop drops it after it fires. It runs on the main
    // thread (the main run loop).
    let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                      false, CFIndex.max) { _, _ in
        MainActor.assumeIsolated { work() }
    }
    CFRunLoopAddObserver(main, observer, .commonModes)
    CFRunLoopWakeUp(main)
}
