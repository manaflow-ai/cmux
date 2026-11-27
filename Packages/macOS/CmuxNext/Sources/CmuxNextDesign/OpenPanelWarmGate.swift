import AppKit
import CoreGraphics
import Darwin
import IOKit

/// When the app's warm-up may make an `NSOpenPanel` (``MadeAheadPanelStore``'s warm check). The three facts it reads
/// are injected, so a test checks the rule with no running app and no console session (`OpenPanelWarmGateTests`).
@MainActor
struct OpenPanelWarmGate: Sendable {
    /// Whether the app's event loop runs (`NSApp.isRunning`).
    var appIsRunning: @MainActor @Sendable () -> Bool
    /// Whether this account is the console user (IOConsoleUsers' session on the console, ``consoleHolderUID(in:)``).
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

extension OpenPanelWarmGate {
    /// The uid of the account whose session WindowServer has on the console, from IOConsoleUsers' entries: the first
    /// one with kCGSSessionOnConsoleKey whose login is not still in progress, as the hq worker gate reads it
    /// (build-fleet screen_share.go consoleHolderFromIOReg) and bench_launch.py `console_user()`; change all three
    /// together. nil when nobody is (the login window). Not SCDynamicStore's `State:/Users/ConsoleUser`: that is the
    /// last account to log in, and a Screen Sharing login to another account's own session (the fleet's hidden CI
    /// accounts, 2026-11-18) takes it over while this account's session stays on the console.
    nonisolated static func consoleHolderUID(in sessions: [[String: Any]]) -> uid_t? {
        for session in sessions {
            guard session["kCGSSessionOnConsoleKey"] as? Bool == true,
                  session["kCGSessionLoginDoneKey"] as? Bool != false else { continue }
            guard session["kCGSSessionUserNameKey"] as? String != "loginwindow",
                  let uid = (session["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value else { return nil }
            return uid_t(uid)
        }
        return nil
    }
}

/// Whether this process's account is the console user (``OpenPanelWarmGate/consoleHolderUID(in:)``). Not
/// `CGSessionCopyCurrentDictionary`: it is nil for a process outside a Quartz GUI session (an app started over SSH, as
/// every fleet bench is), even when its account is on the console. An unreadable registry means nobody.
private func thisAccountIsConsoleUser() -> Bool {
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    guard root != IO_OBJECT_NULL else { return false }
    defer { IOObjectRelease(root) }
    guard let sessions = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? [[String: Any]] else { return false }
    return OpenPanelWarmGate.consoleHolderUID(in: sessions) == getuid()
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
