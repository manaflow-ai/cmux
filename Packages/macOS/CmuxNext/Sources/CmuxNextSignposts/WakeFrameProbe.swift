public import AppKit
import CmuxNextCompat

/// Records `switch.wake` (``WakeFrameSignpost``) on each system and display wake, for the idle ledger's
/// wake-to-first-frame row. Holds two observers and does nothing else.
@MainActor
public final class WakeFrameProbe {
    private var observers: [MainActorObservation] = []

    /// Starts observing; keep the probe alive for the app's life.
    public init() {
        let center = NSWorkspace.shared.notificationCenter
        let sources: [(Notification.Name, WakeFrameSignpost.Source)] = [(NSWorkspace.didWakeNotification, .system), (NSWorkspace.screensDidWakeNotification, .display)]
        observers = sources.map { name, source in MainActorObservation(name, center: center) { WakeFrameSignpost().begin(source: source) } }
    }
}
