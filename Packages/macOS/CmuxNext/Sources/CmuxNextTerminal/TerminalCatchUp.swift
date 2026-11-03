import AppKit
import CmuxNextWakeups
import GhosttyNextKit

/// SWITCH FRAMES SF-5, pre-show (lead decision on #32446, 2026-11-02). A hidden terminal's owner holds its output
/// and sends it once a second (`attach-visibility-v1`, as Chrome aligns a hidden page's timers); shown again, what
/// waits comes one round trip later. A switch then showed the older screen and the newest one a frame or more after
/// it. A terminal that printed while hidden (its lane got bytes since it hid: the owner sends the first one at once)
/// waits here when shown again until it drew everything its owner sent up to the owner's `shown` marker
/// (``TerminalIOEvent/caughtUp``), and the switch keeps what it showed until then (the pane's or the window's
/// `PanePaintHold`), as Chrome's compositor keeps the last frame until an embedded surface it waits for arrives,
/// up to a deadline: a parse that takes longer keeps the last frame, never shows the older screen first. A terminal
/// that printed nothing while hidden shows at once.
@MainActor
final class TerminalCatchUp {
    /// The longest a switch waits for the newest screen (an owner that never sends its marker): then it shows what
    /// the terminal has. The switch's own hold (`PanePaintHold.limit`) ends at the same bound.
    static let limit: Duration = TerminalFrameHold.limit

    /// A switch waits for this terminal now.
    private(set) var isPending = false
    private weak var session: TerminalSession?
    /// The lane and its byte count when the terminal hid: content queued since is newer than its frame.
    private var atHide: (lane: ObjectIdentifier, total: UInt64)?
    /// Every byte owed at the show is parsed: the frame then, and the ticks since. A frame captured before the parse
    /// can still present on the next tick, so only a change seen two ticks on counts (as ``TerminalFrameHold``).
    private var parsed: (frame: AnyObject?, ticks: Int)?
    private var generation = 0
    private var waiters: [() -> Void] = []
    private let deadline = DemandTimer(owner: "TerminalCatchUp.limit")
    private lazy var frames = FrameClient(owner: "TerminalCatchUp", isAnimation: false, scheduler: { [weak self] in
        self?.session.map { FrameScheduler.forView($0.surfaceView) } ?? .app
    }) { [weak self] _ in self?.tick() ?? false }

    /// The surface's lane got content since the terminal hid (or another surface took its place).
    func printedSinceHide(_ surface: TerminalSurfaceView) -> Bool {
        guard let atHide else { return false }
        guard let lane = surface.lane else { return true }
        return ObjectIdentifier(lane) != atHide.lane || lane.queuedTotal != atHide.total
    }

    /// Rendering was suspended (`hidden`) or resumed. Shown again with `catchesUp` (the IO held output while hidden,
    /// ``TerminalIO/catchesUpWhenShown``) after it printed while hidden, a switch waits for the marker.
    func renderingSuspended(_ hidden: Bool, session: TerminalSession, catchesUp: Bool) {
        finish()
        let surface = session.surfaceView
        if hidden {
            atHide = surface.lane.map { (ObjectIdentifier($0), $0.queuedTotal) }
            return
        }
        defer { atHide = nil }
        guard catchesUp, printedSinceHide(surface) else { return }
        isPending = true
        self.session = session
        let generation = generation
        deadline.schedule(after: Self.limit) { @MainActor [weak self] in
            guard let self, self.generation == generation else { return }
            self.finish()
        }
    }

    /// The owner's marker for this show: every byte printed before the show is on the lane. A new link (its attach
    /// starts shown, so no marker comes) ends the wait through its status, else the bound does. Once it is parsed and a frame drawn after that presents, the switch shows it.
    func caughtUp() {
        guard isPending, parsed == nil, let lane = session?.surfaceView.lane else { return }
        frames.activate()
        let generation = generation
        Task { [weak self] in
            await lane.drained()
            guard let self, self.generation == generation, let surface = self.session?.surfaceView else { return }
            self.parsed = (surface.presentedFrame, 0)
            // A frame from the parsed state, even if the renderer has nothing else to draw.
            if let ghostty = surface.surface { ghostty_surface_refresh(ghostty) }
        }
    }

    /// Runs `body` once the terminal drew the newest screen (or past ``limit``); now when no switch waits.
    func whenCaughtUp(_ body: @escaping () -> Void) {
        guard isPending else { return body() }
        waiters.append(body)
    }

    /// The session hid, closed or lost its link: whoever waits shows what there is.
    func finish() {
        generation &+= 1
        isPending = false
        frames.deactivate()
        deadline.cancel()
        session = nil
        parsed = nil
        let waiting = waiters
        waiters = []
        waiting.forEach { $0() }
    }

    private func tick() -> Bool {
        guard isPending, let surface = session?.surfaceView else {
            finish()
            return false
        }
        guard var parsed else { return true }
        parsed.ticks += 1
        self.parsed = parsed
        guard parsed.ticks >= 2, let shown = surface.presentedFrame, shown !== parsed.frame else { return true }
        finish()
        return false
    }
}
