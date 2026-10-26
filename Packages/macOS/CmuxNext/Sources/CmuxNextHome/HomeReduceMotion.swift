import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import MessagesLabHome
import MessagesLabSidebar

/// The vendored Home transcript and conversation list cannot see `Motion` (they are
/// MessagesLab's code), so their Reduce Motion reads a value their host pushes. This pushes
/// `Motion.reduceMotion` (the system setting, calm mode and the tests' pin, cx-sya4n) and, on a
/// change, re-applies it to the live views, so a Reduce Motion change stills or restarts their
/// loops as it does every cmux loop. Its one ``AppearanceSignals`` subscription is the only
/// listener: the views observe nothing themselves (p06-scheduler-043). Installed by the views that
/// host them, before their first frame.
@MainActor
final class HomeReduceMotion {
    private static let shared = HomeReduceMotion()
    private var observer: AppearanceSignals.Subscription?
    /// The live transcripts and lists (weak): told when the value changes.
    private let views = NSHashTable<NSView>.weakObjects()

    private init() {
        Self.push()
        // The list's pin drag reads the gate when a movement starts (speed off, Reduce Motion, settings).
        CmuxSidebarView.movementGate = { Motion.sidebar.animatesMovement }
        // The message box's dictation waveform follows the input level only while Home's loops run.
        MessagesLabHomeView.voiceMotionGate = { Motion.home.animatesLoops }
        observer = DesignSettings.shared.signals.subscribe([.reduceMotion], owner: "HomeReduceMotion") { [weak self] in
            Self.push()
            self?.applyToViews()
        }
    }

    /// Starts pushing (once per process).
    static func install() { _ = shared }

    /// Installs, then re-applies Reduce Motion to `transcript` on each change while it lives.
    static func follow(_ transcript: MessagesLabHomeView) {
        install()
        shared.views.add(transcript)
    }

    /// Installs, then re-applies Reduce Motion to `list` on each change while it lives.
    static func follow(_ list: CmuxSidebarView) {
        install()
        shared.views.add(list)
    }

    private static func push() {
        let reduce = Motion.reduceMotion
        MessagesLabHomeView.reduceMotionOverride = reduce
        CmuxSidebarView.reduceMotionOverride = reduce
    }

    private func applyToViews() {
        for view in views.allObjects {
            if let transcript = view as? MessagesLabHomeView { transcript.applyReduceMotion() }
            if let list = view as? CmuxSidebarView { list.applyReduceMotion() }
        }
    }
}
