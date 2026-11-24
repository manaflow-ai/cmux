import AppKit
import CmuxNextCompat
import CmuxNextSignposts

/// Records `switch.wake` (``WakeFrameSignpost``) on each system and display wake, for the idle ledger's
/// wake-to-first-frame row. Holds two observers and does nothing else.
@MainActor
final class WakeFrameProbe {
    private var observers: [MainActorObservation] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            MainActorObservation(NSWorkspace.didWakeNotification, center: center) { WakeFrameSignpost().begin(source: .system) },
            MainActorObservation(NSWorkspace.screensDidWakeNotification, center: center) { WakeFrameSignpost().begin(source: .display) },
        ]
    }
}
