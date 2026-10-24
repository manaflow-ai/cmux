import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import MessagesLabHome
import MessagesLabSidebar

/// The vendored Home transcript and conversation list cannot see `Motion` (they are
/// MessagesLab's code), so their Reduce Motion reads their own pin and else the system
/// setting. This keeps their pins equal to `Motion.reduceMotionOverride` (cx-sya4n), so a
/// Reduce Motion pin stills them as it stills every cmux loop, and pins them on while calm
/// mode (`ui.calm`) is on, which `Motion.reduceMotion` counts and the system setting does not.
/// Installed by the views that host them, before their first frame.
@MainActor
final class HomeReduceMotion {
    private static let shared = HomeReduceMotion()
    private var observer: (any NSObjectProtocol)?

    private init() {
        Self.mirror()
        // The list's pin drag reads the gate when a movement starts (speed off, Reduce Motion, settings).
        CmuxSidebarView.movementGate = { Motion.sidebar.animatesMovement }
        // The message box's dictation waveform follows the input level only while Home's loops run.
        MessagesLabHomeView.voiceMotionGate = { Motion.home.animatesLoops }
        observer = NotificationCenter.default.addObserver(forName: Motion.reduceMotionDidChange, object: nil, queue: nil) { _ in
            MainDelivery().run { HomeReduceMotion.mirror() }
        }
    }

    /// Starts mirroring (once per process).
    static func install() { _ = shared }

    /// A test's pin wins; calm mode pins Reduce Motion on; else nil, and the vendored views
    /// read the system setting themselves. Calm mode posts `reduceMotionDidChange` when it changes.
    private static func mirror() {
        let pin = Motion.reduceMotionOverride ?? (DesignSettings.shared.calmMode.reducesMotion ? true : nil)
        MessagesLabHomeView.reduceMotionOverride = pin
        CmuxSidebarView.reduceMotionOverride = pin
    }
}
