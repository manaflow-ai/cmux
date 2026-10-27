import CmuxNextCompat
import CoreFoundation

/// How ``StartupScheduler`` learns that the main loop went idle for the first time after the app
/// registered its launch work: that ends its `Startup.firstIdle` ref (reason
/// ``StartupInProgressRef/Reason/firstIdle``).
///
/// Chrome records the same moment as `RecordBrowserMainLoopFirstIdle`
/// (components/startup_metric_utils/browser/startup_metric_utils.h): the launch turn and the work it
/// queued ran, and the UI thread had nothing left to do. The app uses ``mainRunLoop``; a scheduler
/// made after the launch, whose main loop idled long ago, and the tests use ``atRegistration`` or a
/// seam they run by hand.
///
/// ```swift
/// let idle = StartupFirstIdle { idle in waiting = idle }  // a test's hand-run first idle
/// ```
public struct StartupFirstIdle: Sendable {
    /// Calls `idle` once, at the first idle of the main loop from now.
    public typealias Arm = @MainActor @Sendable (_ idle: @escaping @MainActor () -> Void) -> Void

    private let arm: Arm

    /// - Parameter arm: Calls its argument once, at the main loop's first idle from the call.
    public init(_ arm: @escaping Arm) {
        self.arm = arm
    }

    /// The app's: the main run loop's first before-waiting stage, ordered after AppKit's display and the
    /// Core Animation commit, so the turn it closes is the whole launch turn (as `DebugTimings`' `first_idle` mark).
    public static var mainRunLoop: StartupFirstIdle {
        StartupFirstIdle { idle in
            MainRunLoopObserver.once(activities: .beforeWaiting, order: MainRunLoopObserver.lastOrder, idle)
        }
    }

    /// The registration itself counts as the first idle: for a scheduler made after the launch and for tests.
    public static var atRegistration: StartupFirstIdle {
        StartupFirstIdle { idle in idle() }
    }

    /// Calls `idle` once, at the main loop's first idle from now.
    @MainActor public func whenIdle(_ idle: @escaping @MainActor () -> Void) {
        arm(idle)
    }
}
