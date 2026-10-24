import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups
import MessagesLabHome
import MessagesLabSidebar

/// The vendored Home transcript and conversation list cannot see `Motion` (they are
/// MessagesLab's code), so their Reduce Motion reads their own pin and else the system
/// setting. This keeps their pins equal to `Motion.reduceMotionOverride` (cx-sya4n), so a
/// Reduce Motion pin stills them as it stills every cmux loop, and it is the one observer of a
/// Reduce Motion change for every Home view: on a pin change or a system setting change it calls
/// `applyReduceMotion()` on the live transcripts and lists that the Home hosts gave it
/// (`follow(_:)`), so loops already running stop or start again. The
/// vendored views observe nothing themselves.
///
/// Process-wide because the pins it mirrors are (the vendored code reads them statically).
///
/// Open debt (2026-10-24, arch-broadcasts-inspect-lab reviews 1 and 2; recorded in
/// architecture-refactor-DESIGN.md section 5): the follower list lives in this
/// static `shared`, reached by the hosts' `install()`/`follow(_:)`. Make one instance in
/// AppServices and pass it to `HomeNativeTranscriptView` and `HomeSidebarView` through their
/// inits (TopHomePageView, HomeHostView, HomeNewMessageView, HomeNativeFixture and the tests make
/// them), so no host reaches a static.
@MainActor
final class HomeReduceMotion {
    /// A Home view that follows Reduce Motion while it lives (held weakly: a closed view drops out).
    private struct Follower {
        weak var view: NSView?
        let apply: @MainActor () -> Void
    }

    private static let shared = HomeReduceMotion()
    private var motionObserver: (any NSObjectProtocol)?
    /// The system setting (Accessibility > Display > Reduce motion), observed once for every Home view.
    private var systemObserver: MainActorObservation?
    private var followers: [Follower] = []

    private init() {
        Self.mirror()
        // The list's pin drag reads the gate when a movement starts (speed off, Reduce Motion, settings).
        CmuxSidebarView.movementGate = { Motion.sidebar.animatesMovement }
        // The message box's dictation waveform follows the input level only while Home's loops run.
        MessagesLabHomeView.voiceMotionGate = { Motion.home.animatesLoops }
        motionObserver = NotificationCenter.default.addObserver(forName: Motion.reduceMotionDidChange, object: nil, queue: nil) { _ in
            MainDelivery().run {
                // `Motion` posts for changes the vendored views ignore (calm mode): re-apply only
                // when a pin they read changed, or a running typing row or bubble restarts its phase.
                if HomeReduceMotion.mirror() { HomeReduceMotion.shared.applyToFollowers() }
            }
        }
        systemObserver = MainActorObservation(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                              center: NSWorkspace.shared.notificationCenter) {
            HomeReduceMotion.shared.applyToFollowers()
        }
    }

    /// Starts mirroring (once per process). Installed by the views that host the vendored ones,
    /// before those make their first loop.
    static func install() { _ = shared }

    /// Re-applies Reduce Motion to `transcript` while it lives (its host calls this once).
    static func follow(_ transcript: MessagesLabHomeView) {
        shared.add(transcript) { [weak transcript] in transcript?.applyReduceMotion() }
    }

    /// Re-applies Reduce Motion to `list` while it lives (its host calls this once).
    static func follow(_ list: CmuxSidebarView) {
        shared.add(list) { [weak list] in list?.applyReduceMotion() }
    }

    private func add(_ view: NSView, apply: @escaping @MainActor () -> Void) {
        followers.removeAll { $0.view == nil }
        followers.append(Follower(view: view, apply: apply))
    }

    /// Every live follower applies the Reduce Motion setting now; closed views drop out.
    private func applyToFollowers() {
        followers.removeAll { $0.view == nil }
        for follower in followers { follower.apply() }
    }

    /// Copies `Motion.reduceMotionOverride` into both vendored pins; true when either changed.
    @discardableResult
    private static func mirror() -> Bool {
        let pin = Motion.reduceMotionOverride
        let changed = MessagesLabHomeView.reduceMotionOverride != pin || CmuxSidebarView.reduceMotionOverride != pin
        MessagesLabHomeView.reduceMotionOverride = pin
        CmuxSidebarView.reduceMotionOverride = pin
        return changed
    }
}
