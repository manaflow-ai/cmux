import AppKit
import CoreGraphics
import Darwin
import SystemConfiguration

/// When the app's warm-up may make an `NSOpenPanel` (``MadeAheadPanelStore``'s warm check). The three facts it reads
/// are injected, so a test checks the rule with no running app and no console session (`OpenPanelWarmGateTests`).
@MainActor
struct OpenPanelWarmGate: Sendable {
    /// Whether the app's event loop runs (`NSApp.isRunning`).
    var appIsRunning: @MainActor @Sendable () -> Bool
    /// Whether this account is the console user (SCDynamicStore `State:/Users/ConsoleUser`).
    var sessionIsOnConsole: @MainActor @Sendable () -> Bool
    /// Whether the person has paused (no input for a second, or cmux in the background) outside a tracking loop.
    var personIsIdle: @MainActor @Sendable () -> Bool

    /// The gate of the running app: reads `NSApp`, the console user and the session's last input event.
    init() {
        self.init(appIsRunning: { NSApp?.isRunning == true }, sessionIsOnConsole: { thisAccountIsConsoleUser() },
                  personIsIdle: { personPausedOutsideTrackingLoop() })
    }

    /// A gate over the given reads (tests).
    init(appIsRunning: @escaping @MainActor @Sendable () -> Bool,
         sessionIsOnConsole: @escaping @MainActor @Sendable () -> Bool,
         personIsIdle: @escaping @MainActor @Sendable () -> Bool) {
        self.appIsRunning = appIsRunning
        self.sessionIsOnConsole = sessionIsOnConsole
        self.personIsIdle = personIsIdle
    }

    /// What the warm-up may do now. Read when a check fires, not when it is scheduled: launch windows come before
    /// the event loop runs.
    func check() -> OpenPanelWarmCheck {
        // Only in a running app: a process that never ran its event loop (a test host, a ci-step mini with no
        // open-panel service) would wait 10 s per ViewBridge endpoint, then die.
        guard appIsRunning() else { return .never(reason: "the app's event loop does not run") }
        // Only when this account is the console user: from SSH or a fleet worker whose account is not, `NSOpenPanel()`
        // blocks the main thread about 40 s on ViewBridge and comes back dead (2026-10-23).
        guard sessionIsOnConsole() else { return .never(reason: "this account is not the console user") }
        return personIsIdle() ? .ready : .busy
    }
}

/// Whether this process's account is the console user: the rule of bench_launch.py `gui_session()` and the hq worker
/// gate (build-fleet console_session.go readConsoleUser); change all three together. `loginwindow` or no console
/// user means nobody. Not `CGSessionCopyCurrentDictionary`: it is nil for a process outside a Quartz GUI session (an
/// app started over SSH, as every fleet bench is), even when its account is on the console.
private func thisAccountIsConsoleUser() -> Bool {
    var uid: uid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?, name != "loginwindow" else { return false }
    return uid == getuid()
}

/// In the background the person types elsewhere: nothing here waits on the main thread. In front, the time since the
/// last input event (kCGAnyInputEventType, ~0) must be a second. Never inside a tracking loop (a drag, a menu, a
/// resize): those count as busy.
@MainActor private func personPausedOutsideTrackingLoop() -> Bool {
    let anyInput = CGEventType(rawValue: ~0) ?? .null
    let idle = NSApp?.isActive == true ? CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) : .infinity
    // RunLoop.current is unavailable in async code; this runs on the main actor.
    return idle >= 1 && RunLoop.main.currentMode == .default
}
