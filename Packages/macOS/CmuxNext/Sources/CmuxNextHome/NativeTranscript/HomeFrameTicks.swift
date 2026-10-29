import AppKit
import CmuxNextWakeups
import MessagesLabHome

/// The MessagesLab controller's display frames (its FrameTick: page landings, the engine jobs a
/// keystroke went ahead of) as a client of the pane window's FrameScheduler, so Home shares the
/// window's one display link instead of making its own (Chrome: one
/// `viz::BeginFrameSource` per display, components/viz/common/frame_sinks/begin_frame_source.h).
///
/// The client is ``FrameRate/motion``: Home typing is key to frame, so it never takes an ambient
/// rate. It is batch work, not animation (``FrameClient/isAnimation`` false): an occluded window
/// keeps ticking it, so a landing or a held engine job is never parked behind occlusion.
@MainActor
final class HomeFrameTicks: FrameTickSource {
    static let owner = "Home.transcript.frame"
    private let scheduler: @MainActor (NSView) -> FrameScheduler

    /// - Parameter scheduler: the scheduler of a view's window (tests pass a fake-link one).
    init(scheduler: @escaping @MainActor (NSView) -> FrameScheduler = FrameScheduler.forView) {
        self.scheduler = scheduler
    }

    func frames(for view: NSView, onFrame: @escaping @MainActor @Sendable () -> Bool) -> any FrameTickStream {
        let resolve = scheduler
        // frame-client: Home's page landings and held engine jobs (key to frame), on main with their controller
        let client = FrameClient(owner: Self.owner, isAnimation: false, rate: .motion,
                                 scheduler: { [weak view] in view.map(resolve) ?? .app }) { _ in onFrame() }
        return HomeFrameTickStream(client: client)
    }
}

/// One FrameTick's client: started for the next frame, idle again after the frame that finds no work.
/// The client resolves its window's scheduler when it activates, so a restart (the view moved to another
/// window) leaves the old scheduler and joins the new one; a client its closed window's scheduler
/// dropped (``FrameScheduler/invalidate()``) is idle, and joins the new one too.
@MainActor
final class HomeFrameTickStream: FrameTickStream {
    let client: FrameClient

    init(client: FrameClient) { self.client = client }

    func start() { client.activate() }

    func restart() {
        client.deactivate()
        client.activate()
    }
}
