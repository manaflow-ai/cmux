import IOSurface

/// What main asks of a surface's presented frames. The renderer is the only writer
/// of the presented contents (rendering-DESIGN.md R5): main reads the frame it presents and hides,
/// shows or purges it through Ghostty, never through the layer. Chrome keeps the same split: the
/// browser holds a reference to the surface's current frame and asks the producer to evict it
/// (`components/viz/service/frame_sinks/frame_evictor.h`), and only the producer submits frames.
///
/// ``GhosttyFrameSource`` is the source for a live surface (``TerminalSurfaceView/frameSource``); tests pass a
/// recorder.
@MainActor
protocol TerminalFrameSource: AnyObject {
    /// The frame the renderer presents now; nil before its first draw or after a purge.
    var presentedFrame: IOSurface? { get }

    /// Tells the renderer what becomes of its presented frame.
    func setPresentation(_ presentation: TerminalPresentation)
}

/// `ghostty_surface_set_presentation`'s argument.
enum TerminalPresentation: Equatable {
    /// Nothing shows the frame: its pages may be taken.
    case hidden
    /// The frame shows again.
    case shown
    /// The frame's pages were taken: the renderer drops it, so no reader sees an empty frame.
    case purge
}
