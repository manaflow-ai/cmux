import AppKit
import CoreGraphics
import Foundation

/// Decides whether the user is actively at this Mac right now.
///
/// Used by the phone-forwarding gate: when the user is already looking at the
/// Mac there is no point buzzing the iPhone too. The Mac counts as ACTIVE only
/// when ALL of the following hold:
///
/// 1. The console session belongs to the current user and is unlocked (no
///    login window, no fast-user-switch away, no lock screen).
/// 2. Displays are awake and the screensaver is not running.
/// 3. The last HARDWARE user input was within
///    ``recentHardwareInputThreshold`` seconds. Hardware input is read from
///    `CGEventSource`'s `.hidSystemState` — deliberately NOT
///    `.combinedSessionState` — so synthetic events (cmux agents driving the
///    debug socket, accessibility automation, event-posting tools) do not
///    count as the user being present. Input injected from the phone via
///    mobile RPC is dispatched in-process and never reaches the HID state
///    either, so driving the Mac from the phone correctly counts as "away".
///
/// Locking the screen, display sleep, or the screensaver starting flip the
/// answer to "away" immediately; only the input-recency rule has the
/// ``recentHardwareInputThreshold`` window.
struct MacPresenceMonitor {
    /// Hardware input within this window counts as actively using the Mac.
    /// The single source of truth for the threshold; UI copy derives from it.
    static let recentHardwareInputThreshold: TimeInterval = 120

    /// A snapshot of the presence signals at one instant.
    struct Signals {
        /// The console session is the current user's and is not locked.
        var isConsoleSessionActiveAndUnlocked: Bool
        var areDisplaysAwake: Bool
        var isScreensaverRunning: Bool
        /// Seconds since the last hardware keyboard/mouse event; `nil` when
        /// unknown (treated as away).
        var secondsSinceLastHardwareInput: TimeInterval?
    }

    enum Verdict: Equatable {
        case active(secondsSinceLastHardwareInput: TimeInterval)
        case awayConsoleSessionInactiveOrLocked
        case awayDisplaysAsleep
        case awayScreensaverRunning
        case awayNoRecentHardwareInput(secondsSinceLastHardwareInput: TimeInterval?)

        var isActive: Bool {
            if case .active = self { return true }
            return false
        }
    }

    struct Decision: Equatable {
        var verdict: Verdict
        var evaluatedAt: Date

        var isActive: Bool { verdict.isActive }
    }

    /// Injected clock so tests are deterministic.
    var now: () -> Date
    /// Injected signal provider so the heuristic is unit-testable.
    var signals: () -> Signals

    func evaluate() -> Decision {
        Decision(verdict: Self.verdict(for: signals()), evaluatedAt: now())
    }

    /// Pure heuristic over one signals snapshot. Order matters: lock state,
    /// display sleep, and screensaver each force "away" instantly regardless
    /// of how recent the last input was.
    static func verdict(for signals: Signals) -> Verdict {
        guard signals.isConsoleSessionActiveAndUnlocked else {
            return .awayConsoleSessionInactiveOrLocked
        }
        guard signals.areDisplaysAwake else {
            return .awayDisplaysAsleep
        }
        guard !signals.isScreensaverRunning else {
            return .awayScreensaverRunning
        }
        guard let idle = signals.secondsSinceLastHardwareInput,
              idle <= recentHardwareInputThreshold
        else {
            return .awayNoRecentHardwareInput(
                secondsSinceLastHardwareInput: signals.secondsSinceLastHardwareInput
            )
        }
        return .active(secondsSinceLastHardwareInput: idle)
    }
}

extension MacPresenceMonitor {
    /// Production monitor backed by the real WindowServer/HID signals. The
    /// live monitor is owned and evaluated by `PhonePushClient` on the main
    /// actor; `liveConsoleSessionActiveAndUnlocked` asserts that isolation
    /// when it reads the lock observer.
    @MainActor
    static func live(now: @escaping () -> Date = Date.init) -> MacPresenceMonitor {
        // Start observing lock transitions as early as possible so the
        // notification-based source has seen any lock that predates the
        // first presence evaluation.
        _ = ScreenLockObserver.shared
        return MacPresenceMonitor(now: now, signals: liveSignals)
    }

    private static func liveSignals() -> Signals {
        Signals(
            isConsoleSessionActiveAndUnlocked: liveConsoleSessionActiveAndUnlocked(),
            areDisplaysAwake: CGDisplayIsAsleep(CGMainDisplayID()) == 0,
            isScreensaverRunning: liveScreensaverRunning(),
            secondsSinceLastHardwareInput: liveSecondsSinceLastHardwareInput()
        )
    }

    private static func liveConsoleSessionActiveAndUnlocked() -> Bool {
        // The live monitor's evaluation context is the main actor (it is
        // owned by the @MainActor PhonePushClient); assumeIsolated makes
        // that contract explicit and traps loudly if it is ever violated.
        let observedScreenLocked = MainActor.assumeIsolated {
            ScreenLockObserver.shared.isLockedObserved
        }
        return consoleSessionActiveAndUnlocked(
            sessionDictionary: CGSessionCopyCurrentDictionary() as? [String: Any],
            observedScreenLocked: observedScreenLocked
        )
    }

    /// Pure decision over the two lock-state sources (see ``ScreenLockObserver``
    /// for why both are consulted). Exposed for behavior tests.
    ///
    /// `CGSessionCopyCurrentDictionary()` returns `nil` when the calling
    /// process has no WindowServer session at all; treat that as away.
    /// `kCGSessionOnConsoleKey` is false while the login window owns the
    /// console or another user fast-switched in. The de-facto
    /// `CGSSessionScreenIsLocked` key appears in the dictionary (as true)
    /// while the lock screen is up; when it is absent, the observed
    /// distributed-notification state still reports the lock.
    static func consoleSessionActiveAndUnlocked(
        sessionDictionary: [String: Any]?,
        observedScreenLocked: Bool
    ) -> Bool {
        guard let sessionDictionary else { return false }
        let onConsole = (sessionDictionary[kCGSessionOnConsoleKey as String] as? Bool) ?? false
        let dictionaryLocked = (sessionDictionary["CGSSessionScreenIsLocked"] as? Bool) ?? false
        return onConsole && !dictionaryLocked && !observedScreenLocked
    }

    private static func liveScreensaverRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.ScreenSaver.Engine"
        }
    }

    /// Min across keyboard, mouse-move, mouse-down, and scroll HID timestamps.
    /// `.hidSystemState` deliberately excludes session-synthesized events (see
    /// type docs for why synthetic agent input must not count as presence).
    private static func liveSecondsSinceLastHardwareInput() -> TimeInterval? {
        let eventTypes: [CGEventType] = [
            .keyDown,
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
        ]
        let seconds = eventTypes
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .filter { $0.isFinite && $0 >= 0 }
        return seconds.min()
    }
}
