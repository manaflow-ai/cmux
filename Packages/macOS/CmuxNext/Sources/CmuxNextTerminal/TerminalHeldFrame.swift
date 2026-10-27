import CmuxNextCompat
import IOSurface

/// The frame a paused ``TerminalSurfaceView`` keeps presented: volatile until the surface draws again
/// (CmuxNextCompat's `IOSurface.makeVolatile()`), so memory pressure may take it. Drawing again makes it non-volatile
/// before the next commit; a purged one is dropped by its renderer (``TerminalPresentation/purge``), so
/// the pane is empty until Ghostty's next frame.
@MainActor
struct TerminalHeldFrame {
    /// The presented frame made volatile while the surface does not draw.
    private(set) var frame: IOSurface?

    /// The surface paused (`volatile`) or draws again. A frame in flight at the pause may have replaced
    /// the held one: that one is not volatile. The held frame is reclaimed before the renderer is told it
    /// shows, so a purged one is dropped first and the show queues a fresh frame (ghostty.h: SHOWN after
    /// PURGE queues a frame; PURGE after SHOWN would leave the pane hidden).
    mutating func hold(volatile: Bool, in source: some TerminalFrameSource) {
        let presented = source.presentedFrame
        if volatile {
            frame = presented
            frame?.makeVolatile()
            source.setPresentation(.hidden)
            return
        }
        if let held = frame {
            frame = nil
            if presented === held, !held.reclaim() { source.setPresentation(.purge) }
        }
        source.setPresentation(.shown)
    }

    /// The presented frame for one reader (hover pictures): a held frame is made non-volatile for the
    /// read (nil when purged); ``endRead(_:)`` makes it volatile again.
    mutating func beginRead(from source: some TerminalFrameSource) -> IOSurface? {
        guard let presented = source.presentedFrame else { return nil }
        guard presented === frame else { return presented }
        guard presented.reclaim() else {
            frame = nil
            source.setPresentation(.purge)
            return nil
        }
        return presented
    }

    /// The read of `read` ended.
    func endRead(_ read: IOSurface) {
        if read === frame { read.makeVolatile() }
    }
}
