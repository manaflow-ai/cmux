import CmuxNextCompat
import CoreFoundation

/// Runs `work` once, on the main run loop's next pass to the point where it
/// waits for events, after AppKit displayed its windows and Core Animation
/// committed the frame they drew: work that frame does not show starts only
/// once the frame is on its way to the screen.
///
/// A main-actor `Task` would run earlier: the run loop drains the main queue
/// before that point, so the work would delay the frame it tries to follow.
func scheduleAfterFrameCommit(_ work: @escaping @MainActor () -> Void) {
    // A before-waiting run loop observer: the frame commit point has no async-native signal.
    // Ordered last (`CFIndex.max`), after AppKit's display and Core Animation's commit
    // observers. The pass in progress reaches that point, so it needs no wakeup.
    MainRunLoopObserver.once(activities: .beforeWaiting, order: .max, work)
}
