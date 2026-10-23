import AppKit
import CoreGraphics

/// What ``MadeAheadOpenPanel``'s warm-up reads from the outside world, so a test can stand in for a panel
/// service that never answers. ``live`` is the app's.
struct MadeAheadOpenPanelWorld: Sendable {
    /// Whether a warm-up check may make the panel now.
    enum Gate: Sendable {
        /// The person is idle and no tracking loop runs.
        case go
        /// Input or a tracking loop: check again later.
        case busy
        /// No running app event loop (a test host): never warm.
        case never
    }

    /// Makes a panel on the main thread (`NSOpenPanel()`); nil when it could not.
    var makePanel: @MainActor @Sendable () -> NSOpenPanel?
    /// Off the main thread: whether the open panel's view service can answer this process.
    var serviceReady: @Sendable () async -> Bool
    /// Whether a check may make the panel now.
    var gate: @MainActor @Sendable () -> Gate
    /// The first check's delay after a view asks, and the delay between busy checks.
    var firstCheck: Duration = .seconds(2)
    var retry: Duration = .seconds(1)
    /// How long ``serviceReady`` may take before the warm-up gives up for this launch.
    var serviceDeadline: Duration = .milliseconds(500)
    /// The clock of the checks and the service deadline.
    var clock: any Clock<Duration> = ContinuousClock()

    /// The app's world: AppKit's panel, the console session check, the app's input state.
    static let live = MadeAheadOpenPanelWorld(
        makePanel: { NSOpenPanel() },
        serviceReady: { true },
        gate: {
            // Only in a running app: a process that never ran its event loop (a test host, a ci-step
            // mini with no open-panel service) would wait 10 s per ViewBridge endpoint.
            // Checked at check time, not at schedule time: launch windows come before the loop runs.
            guard NSApp?.isRunning == true else { return .never }
            // In the background the person types elsewhere: nothing here waits on the main thread.
            // In front, the time since the last input event (kCGAnyInputEventType, ~0).
            let anyInput = CGEventType(rawValue: ~0) ?? .null
            let idle = NSApp?.isActive == true
                ? CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) : .infinity
            // Never inside a tracking loop (a drag, a menu, a resize): those count as busy.
            return idle >= 1 && RunLoop.main.currentMode == .default ? .go : .busy
        })
}
