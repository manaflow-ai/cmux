import AppKit
import CoreGraphics
import SystemConfiguration

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
        serviceReady: { await consoleIsThisAccount() },
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

/// Whether this process's account owns the console's GUI session (SCDynamicStore's console user). Without it
/// the open panel's view service never answers, and `NSOpenPanel()` waits on it about 40 s on the main thread
/// (aws-m4pro-3, 2026-10-23: the login window on the console; aws-m4pro-4: another account's session).
@concurrent private func consoleIsThisAccount() async -> Bool {
    var uid: uid_t = 0
    guard let user = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?, user != "loginwindow" else { return false }
    return uid == getuid()
}
