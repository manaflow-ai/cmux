import AppKit

/// Remembers who asked for the next quit. A `quit` action run records its
/// origin before it calls `NSApp.terminate`; a quit nobody recorded (the
/// Dock's Quit, a quit Apple event) is interactive. Once the system posts
/// `NSWorkspace.willPowerOffNotification` (shut down, restart, log out)
/// every quit is `.powerOff`, which never asks.
@MainActor
final class QuitOriginTracker {
    private var pending: QuitOrigin?
    private(set) var isPoweringOff = false

    /// The app keeps one for its lifetime; the observer holds it weakly.
    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        _ = center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPoweringOff = true }
        }
    }

    /// Records the origin of the quit about to start.
    func record(_ origin: QuitOrigin) {
        pending = origin
    }

    /// The origin of the quit AppKit is asking about, cleared for the next.
    /// `appleEventReason` is the quit Apple event's `kAEQuitReason`, when
    /// the quit came from one (logout and shutdown send one).
    func consume(appleEventReason: OSType? = nil) -> QuitOrigin {
        defer { pending = nil }
        if isPoweringOff || appleEventReason.map(Self.powerOffReasons.contains) == true { return .powerOff }
        return pending ?? .interactive
    }

    /// `kAEQuitReason` values the system sends while logging out, restarting
    /// or shutting down.
    static let powerOffReasons: Set<OSType> = [
        OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAERestart), OSType(kAEShutDown),
        OSType(kAEShowRestartDialog), OSType(kAEShowShutdownDialog),
    ]
}
