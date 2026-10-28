// From MessagesLab bd65bbf appkit-native/Sources/FrameTick.swift (not vendored: it is a
// Host.swift helper). cmux: main-actor isolated, and its frames come from an injected
// ``FrameTickSource`` instead of a display link of its own.
import AppKit

/// Display frames for Home's ``FrameTick``. A host hands one to ``MessagesLabHomeView``: CmuxNext
/// passes a client of the pane window's FrameScheduler, so Home shares the window's one display link
/// (Chrome: one `viz::BeginFrameSource` per display, its consumers `BeginFrameObserver`s,
/// components/viz/common/frame_sinks/begin_frame_source.h). Hosts without a frame scheduler of their
/// own (tests, standalone MessagesLab) use ``DisplayLinkFrameTicks``.
@MainActor
public protocol FrameTickSource: AnyObject {
    /// Frames of `view`'s screen: after ``FrameTickStream/start()``, `onFrame` runs at the start of
    /// each display frame until it returns false, which stops the stream until the next `start()`.
    /// `onFrame` is `@Sendable`: CmuxNext (Swift 6) infers that for every main-actor function type, and a
    /// witness must match it in both language modes.
    func frames(for view: NSView, onFrame: @escaping @MainActor @Sendable () -> Bool) -> any FrameTickStream
}

/// One ``FrameTickSource`` stream (one per ``FrameTick``).
@MainActor
public protocol FrameTickStream: AnyObject {
    /// Starts frames; no effect while they run.
    func start()
    /// Starts frames from the display of the view's window now, even while they run: the view moved
    /// to another window, or to none, and the old window's frames may have stopped without a call
    /// back (its scheduler went with it).
    func restart()
}

/// Runs work at the start of the next display frame of a view's screen: a frame stream that
/// stops while nothing waits (no polling).
///
/// Users: page landings (Pager) and the engine jobs a keystroke went ahead of
/// (Host.dispatch). A landing that arrived from the loader queue late in a frame
/// committed after the frame's deadline (a 2 ms commit, still a dropped frame in a
/// knob drag over the 1M store); at the frame's start it has the whole frame.
@MainActor
final class FrameTick {
    private weak var view: NSView?
    private let source: any FrameTickSource
    private var stream: (any FrameTickStream)?
    private var work: [() -> Void] = []
    /// cmux: display frames this tick ran (automation: the frames between a hand-off and the line's close).
    private(set) var fires = 0

    init(view: NSView, source: any FrameTickSource) {
        self.view = view
        self.source = source
    }

    func next(_ f: @escaping () -> Void) {
        work.append(f)
        if let stream { stream.start(); return }
        guard let view else { f(); work.removeAll(); return }
        let frames = source.frames(for: view) { [weak self] in self?.fire() ?? false }
        stream = frames
        frames.start()
    }

    /// The view moved to another window (or out of one): work that waits follows it to the new
    /// window's frames. The old window's stream may have stopped without a frame (the window closed),
    /// and the flags of the callers that wait for this work keep them from asking again.
    func viewDidMoveToWindow() {
        guard !work.isEmpty, let stream else { return }
        stream.restart()
    }

    /// One display frame: runs the work that waited for it; true while work posted meanwhile waits
    /// for the next one.
    private func fire() -> Bool {
        fires += 1
        let w = work
        work.removeAll(keepingCapacity: true)
        for f in w { f() }
        return !work.isEmpty
    }
}
