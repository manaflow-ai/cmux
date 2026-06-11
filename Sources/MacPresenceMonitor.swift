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

/// Coalesces presence evaluations under notification bursts. Only ACTIVE
/// (suppressing) decisions are reused, for up to ``ttl``: bursts while the
/// user is at the Mac are the case where live signal sampling (WindowServer
/// session dictionary, display state, running apps, HID timestamps) would
/// otherwise hammer the main actor. AWAY decisions are never reused, so the
/// user-return transition is detected on the very next notification and a
/// stale away answer can never forward terminal content while the user is
/// back at the Mac. The asymmetry is deliberate: a stale active answer can
/// only suppress a push within 1 s of the user leaving (marginal by design;
/// suppressed pushes are never retroactively sent), while a stale away
/// answer would violate the gate's whole point.
struct MacPresenceDecisionCache {
    static let ttl: TimeInterval = 1.0

    private var last: MacPresenceMonitor.Decision?

    mutating func decision(from monitor: MacPresenceMonitor) -> MacPresenceMonitor.Decision {
        let now = monitor.now()
        if let last,
           last.isActive,
           now >= last.evaluatedAt,
           now.timeIntervalSince(last.evaluatedAt) < Self.ttl {
            return last
        }
        let fresh = monitor.evaluate()
        last = fresh
        return fresh
    }
}

extension MacPresenceMonitor {
    /// Production monitor backed by the real WindowServer/HID signals.
    static func live(now: @escaping () -> Date = Date.init) -> MacPresenceMonitor {
        MacPresenceMonitor(now: now, signals: liveSignals)
    }

    private static func liveSignals() -> Signals {
        Signals(
            isConsoleSessionActiveAndUnlocked: liveConsoleSessionActiveAndUnlocked(),
            areDisplaysAwake: CGDisplayIsAsleep(CGMainDisplayID()) == 0,
            isScreensaverRunning: liveScreensaverRunning(),
            secondsSinceLastHardwareInput: liveSecondsSinceLastHardwareInput()
        )
    }

    /// `CGSessionCopyCurrentDictionary()` returns `nil` when the calling
    /// process has no WindowServer session at all; treat that as away.
    /// `kCGSessionOnConsoleKey` is false while the login window owns the
    /// console or another user fast-switched in. Screen-lock state has no
    /// public constant; the de-facto `CGSSessionScreenIsLocked` key appears in
    /// this dictionary (as true) while the lock screen is up.
    private static func liveConsoleSessionActiveAndUnlocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        let onConsole = (dict[kCGSessionOnConsoleKey as String] as? Bool) ?? false
        let locked = (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
        return onConsole && !locked
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
