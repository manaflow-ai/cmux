import IOSurface
import QuartzCore

/// The frame a paused ``TerminalSurfaceView`` keeps on its layer: volatile until the surface draws again
/// (``TerminalFramePurgeability``), so memory pressure may take it. Drawing again makes it non-volatile
/// before the next commit; a purged one leaves the layer empty until Ghostty's next frame.
struct TerminalHeldFrame {
    /// The presented frame made volatile while the surface does not draw.
    private(set) var frame: IOSurface?

    /// The surface paused (`volatile`) or draws again, `presented` on `layer`. A frame in flight at the
    /// pause may have replaced the held one: that one is not volatile.
    mutating func hold(volatile: Bool, presented: IOSurface?, layer: CALayer?) {
        if volatile {
            frame = presented
            frame?.makeVolatile()
        } else if let held = frame {
            frame = nil
            guard presented === held else { return }
            if !held.reclaim() { layer?.contents = nil }
        }
    }

    /// `presented` for one reader (hover pictures): a held frame is made non-volatile for the read (nil
    /// when purged); ``endRead(_:)`` makes it volatile again.
    mutating func beginRead(presented: IOSurface?, layer: CALayer?) -> IOSurface? {
        guard let presented else { return nil }
        guard presented === frame else { return presented }
        guard presented.reclaim() else {
            frame = nil
            layer?.contents = nil
            return nil
        }
        return presented
    }

    /// The read of `read` ended.
    func endRead(_ read: IOSurface) {
        if read === frame { read.makeVolatile() }
    }
}
