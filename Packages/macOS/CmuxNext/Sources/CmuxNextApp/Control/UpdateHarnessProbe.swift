#if DEBUG
import AppKit
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
    private var observation: Task<Void, Never>?
    private var frames: FrameClient?
    private var ticks = 0
    private var observers: [any NSObjectProtocol] = []
    private var closes: Task<Void, Never>?

    private init(harness: UpdateHarness) {
        self.harness = harness
    }

    /// Starts the probe when this build is a harness copy; no-op otherwise.
    static func install(updater: UpdaterService) {
        guard shared == nil, let harness = UpdateHarness.current else { return }
        let probe = UpdateHarnessProbe(harness: harness)
        shared = probe
        probe.start(updater)
    }

    private func start(_ updater: UpdaterService) {
        // task-owner: the probe, which lives for the process (static shared).
        observation = Task { [weak self, weak updater] in
            for await installing in Observations({ updater?.readyCard?.isInstalling == true }) where installing {
                self?.feedbackState()
                return
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [harness] _ in
            harness.mark("will_terminate")
        })
        // task-owner: the probe, which lives for the process (static shared).
        closes = Task { [harness] in
            for await note in NotificationCenter.default.notifications(named: NSWindow.willCloseNotification) {
                guard let closing = note.object as? NSWindow, closing.canBecomeMain else { continue }
                let others = NSApp.windows.filter { $0 !== closing && $0.isVisible && $0.canBecomeMain }
                harness.mark("main_window_closed.remaining_\(others.count)")
            }
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
