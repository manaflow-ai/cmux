public import AppKit
import CmuxNextCompat

/// Remembers who asked for the next quit. A `quit` action run records its
/// origin before it calls `NSApp.terminate`; a quit nobody recorded (the
/// Dock's Quit, a quit Apple event) is interactive. Once the system posts
/// `NSWorkspace.willPowerOffNotification` (shut down, restart, log out)
/// every quit is `.powerOff`, which never asks.
@MainActor
public final class QuitOriginTracker {
    private var pending: QuitOrigin?
    public private(set) var isPoweringOff = false
    private var powerOff: MainActorObservation?
    #if DEBUG || CMUX_BENCH_HOOKS
    private let center: NotificationCenter
    #endif

    /// The app keeps one for its lifetime; the observer holds it weakly.
    public init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        #if DEBUG || CMUX_BENCH_HOOKS
        self.center = center
        #endif
        powerOff = MainActorObservation(NSWorkspace.willPowerOffNotification, center: center) { [weak self] in
            self?.isPoweringOff = true
        }
    }

    /// Records the origin of the quit about to start.
    public func record(_ origin: QuitOrigin) {
        pending = origin
    }

    /// The origin of the quit AppKit is asking about, cleared for the next.
    /// `appleEventReason` is the quit Apple event's `kAEQuitReason`, when
    /// the quit came from one (logout and shutdown send one).
    public func consume(appleEventReason: OSType? = nil) -> QuitOrigin {
        defer { pending = nil }
        if isPoweringOff || appleEventReason.map(Self.powerOffReasons.contains) == true { return .powerOff }
        return pending ?? .interactive
    }

    /// `kAEQuitReason` values the system sends while logging out, restarting
    /// or shutting down.
    public static let powerOffReasons: Set<OSType> = [
        OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAERestart), OSType(kAEShutDown),
        OSType(kAEShowRestartDialog), OSType(kAEShowShutdownDialog),
    ]

    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.app.terminate {reason}`: quits as REASON does, through the app's own path, for the reopen films
    /// (REOPEN VIDEO, 2026-11-02: the logout case without a quit Apple event, which needs an Automation consent
    /// the fleet never gives). Returns the refusal, or nil when the quit started.
    /// `logout` (the only reason so far): a logout first posts `NSWorkspace.willPowerOffNotification`, then
    /// terminates the app, so every observer of that notice (this tracker among them: the quit is `.powerOff` and
    /// never asks) sees what it sees at a real logout.
    public func debugTerminate(reason: String?, terminate: @MainActor () -> Void) -> String? {
        guard reason == "logout" else { return "reason must be \"logout\", not \(String(describing: reason))" }
        center.post(name: NSWorkspace.willPowerOffNotification, object: NSWorkspace.shared)
        terminate()
        return nil
    }
    #endif
}
