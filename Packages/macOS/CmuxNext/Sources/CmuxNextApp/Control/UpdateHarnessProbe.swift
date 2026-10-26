#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextCompat
import CmuxNextUpdater
import CmuxNextWakeups

/// The App half of the update harness (``UpdateHarness``, DEV only): marks
/// when the update card first says Installing, the next two display
/// refreshes from then (the click's visible feedback), each main window's close during the update quit, and the
/// app's terminate. The harness reads the marks; no product behavior
/// depends on them.
@MainActor
final class UpdateHarnessProbe {
    private static var shared: UpdateHarnessProbe?
    private let harness: UpdateHarness
    /// Follows the card until it first says Installing.
    private var installing: ServiceObservation<Bool>?
    private var sawInstalling = false
    private var frames: FrameClient?
    private var ticks = 0
    private var terminate: EventSubscription?
    private var closes: MainActorObservation?

    private init(harness: UpdateHarness) {
        self.harness = harness
    }

    /// Starts the probe when this build is a harness copy; no-op otherwise.
    ///
    /// - Parameters:
    ///   - updater: The app's updater, whose card the probe follows.
    ///   - mainWork: The app's main-thread scheduler.
    ///   - appEvents: The app's ``AppEvents`` on the default center.
    static func install(updater: UpdaterService, mainWork: MainWorkScheduler, appEvents: AppEvents) {
        guard shared == nil, let harness = UpdateHarness.current else { return }
        let probe = UpdateHarnessProbe(harness: harness)
        shared = probe
        probe.start(updater, mainWork: mainWork, appEvents: appEvents)
    }

    /// Follows `isInstalling` as the probe follows the card: a `visible` service observation. The person's Install
    /// click is the change: its flush runs in that click's input response, before the commit. The updater's own move
    /// to Installing flushes on the next frame, never held behind the person's response as automation is.
    ///
    /// - Parameters:
    ///   - mainWork: The app's main-thread scheduler.
    ///   - isInstalling: Whether the card says Installing; read on the main actor with tracking.
    ///   - apply: Each new value, the first one before this returns.
    static func followInstalling(on mainWork: MainWorkScheduler, _ isInstalling: @escaping @MainActor () -> Bool,
                                 apply: @escaping @MainActor (Bool) -> Void) -> ServiceObservation<Bool> {
        ServiceObservation(.visible, owner: "UpdateHarnessProbe.installing", on: mainWork, read: isInstalling, apply: apply)
    }

    private func start(_ updater: UpdaterService, mainWork: MainWorkScheduler, appEvents: AppEvents) {
        installing = Self.followInstalling(on: mainWork) { [weak updater] in
            updater?.readyCard?.isInstalling == true || updater?.card == .installing
        } apply: { [weak self] isInstalling in
            guard isInstalling, let self, !self.sawInstalling else { return }
            self.sawInstalling = true
            self.installing?.cancel()
            self.feedbackState()
        }
        // raw-observer-allow: the name opens a subscription on the app's one AppEvents (recipe R-notif)
        terminate = appEvents.subscribe(NSApplication.willTerminateNotification, owner: "UpdateHarnessProbe.terminate") { [harness] in
            harness.mark("will_terminate")
        }
        // raw-observer-allow: the mark needs the closing window, the notice's sender; AppEvents hands no sender
        closes = MainActorObservation(NSWindow.willCloseNotification, read: { $0.object as? NSWindow }) { [harness] closing in
            guard let closing, closing.canBecomeMain else { return }
            let others = NSApp.windows.filter { $0 !== closing && $0.isVisible && $0.canBecomeMain }
            harness.mark("main_window_closed.remaining_\(others.count)")
        }
    }

    /// The card's model says Installing: the next display refreshes show it
    /// (AppKit commits the change at the end of this run-loop turn).
    private func feedbackState() {
        harness.mark("feedback_state")
        startLink()
    }

    private func startLink() {
        guard frames == nil, let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        // The first real frame after the commit is the frame that shows the
        // feedback; the second bounds a view that updated one commit later.
        // A synthesized (stalled) tick is marked as such.
        let frames = FrameClient(owner: "UpdateHarnessProbe", isAnimation: false, on: FrameScheduler.forWindow(window)) { [weak self] tick in
            guard let self else { return false }
            self.ticks += 1
            let suffix = tick.refreshInterval == nil ? ".stalled" : ""
            self.harness.mark((self.ticks == 1 ? "feedback_frame" : "feedback_frame_2") + suffix)
            return self.ticks < 2
        }
        self.frames = frames
        frames.activate()
    }
}
#endif
