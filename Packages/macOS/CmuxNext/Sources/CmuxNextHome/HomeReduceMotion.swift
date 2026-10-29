import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import MessagesLabHome
import MessagesLabSidebar

/// The vendored Home transcript and conversation list cannot see `Motion` (they are
/// MessagesLab's code), so their Reduce Motion reads a value their host pushes. This pushes
/// `Motion.reduceMotion` (the system setting, calm mode and the tests' pin, cx-sya4n) and their
/// loop gate (`hostStillsLoops` = `!animatesLoops`: Energy Saver, the speed or the category off)
/// and, on a change, re-applies them to the live views, so a change stills or
/// restarts their loops as it does every cmux loop. Its one ``AppearanceSignals`` subscription is the only
/// listener: the views observe nothing themselves. Installed by the views that
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
        // The message box's dictation waveform follows the person's voice: it moves unless Reduce
        // Motion or Home's motion is off, Energy Saver or not (person-started motion).
        MessagesLabHomeView.voiceMotionGate = { Motion.home.animatesBlinks }
        // `.motion` too: Energy Saver, the speed and the motion switches still or restart the loops.
        observer = DesignSettings.shared.signals.subscribe([.reduceMotion, .motion], owner: "HomeReduceMotion") { [weak self] in
            // Only a changed value re-applies: a running typing row restarts its dots from now.
            guard Self.push() else { return }
            self?.applyToViews()
        }
    }

    /// Starts pushing (once per process).
    static func install() { _ = shared }

    /// Installs, then re-applies Reduce Motion to `transcript` on each change while it lives.
    static func follow(_ transcript: MessagesLabHomeView) {
        install()
        // The message box's send fade is an opacity change: it runs while Home's fades animate.
        transcript.fadeMotionGate = { Motion.home.animatesFades }
        shared.views.add(transcript)
    }

    /// Installs, then re-applies Reduce Motion to `list` on each change while it lives.
    static func follow(_ list: CmuxSidebarView) {
        install()
        shared.views.add(list)
    }

    /// Pushes Reduce Motion and each view's loop gate (`hostStillsLoops`: Energy Saver, the speed off,
    /// the category off); true when a value the views read changed.
    @discardableResult
    private static func push() -> Bool {
        let reduce = Motion.reduceMotion
        let transcriptStill = !Motion.home.animatesLoops, listStill = !Motion.sidebar.animatesLoops
        let changed = MessagesLabHomeView.reduceMotionOverride != reduce || CmuxSidebarView.reduceMotionOverride != reduce
            || MessagesLabHomeView.hostStillsLoops != transcriptStill || CmuxSidebarView.hostStillsLoops != listStill
        MessagesLabHomeView.reduceMotionOverride = reduce
        CmuxSidebarView.reduceMotionOverride = reduce
        MessagesLabHomeView.hostStillsLoops = transcriptStill
        CmuxSidebarView.hostStillsLoops = listStill
        return changed
    }

    private func applyToViews() {
        for view in views.allObjects {
            if let transcript = view as? MessagesLabHomeView { transcript.applyReduceMotion() }
            if let list = view as? CmuxSidebarView { list.applyReduceMotion() }
        }
    }
}
