import IOSurface

/// The frame a paused ``TerminalSurfaceView`` keeps presented: volatile until the surface draws again
/// (``TerminalFramePurgeability``), so memory pressure may take it. Drawing again makes it non-volatile
/// before the next commit; a purged one is dropped by its renderer (``TerminalPresentation/purge``), so
/// the pane is empty until Ghostty's next frame.
@MainActor
struct TerminalHeldFrame {
    /// The presented frame made volatile while the surface does not draw.
    private(set) var frame: IOSurface?

    /// The surface paused (`volatile`) or draws again. A frame in flight at the pause may have replaced
    /// the held one: that one is not volatile.
    mutating func hold(volatile: Bool, in source: some TerminalFrameSource) {
        let presented = source.presentedFrame
        if volatile {
            frame = presented
            frame?.makeVolatile()
            source.setPresentation(.hidden)
            return
        }
        source.setPresentation(.shown)
        guard let held = frame else { return }
        frame = nil
        guard presented === held else { return }
        if !held.reclaim() { source.setPresentation(.purge) }
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
