public import CoreGraphics
import IOSurface

/// An evicted terminal's last presented frame (cx-8w027.10 item b). The warm set closes a hidden
/// terminal's surface; its last IOSurface stays, volatile (the system may reclaim its pages under
/// memory pressure, which is why the terminal was evicted), so the terminal shows that frame at
/// once when it is shown again, until its fresh surface draws the replay
/// (``TerminalSession/showLastFrame(_:)``), and the hover card pictures it on demand. No copy, no
/// readback.
@MainActor
public final class TerminalLastFrame {
    private let surface: IOSurface
    /// Readers that need the pages now (a hover card render), and whether a new surface owns the
    /// frame for good: it is volatile only while neither holds.
    private var pins = 0
    private var taken = false
    /// The system reclaimed the pages once: the frame is gone for good.
    private var purged = false

    /// The frame `session` presents now; nil before its first draw.
    public init?(of session: TerminalSession) {
        guard let surface = session.surfaceView.presentedFrame else { return nil }
        self.surface = surface
        surface.setPurgeable(.volatile, oldState: nil)
    }

    /// The frame for a new surface that shows it from now on (non-volatile for good); nil when
    /// the system reclaimed it.
    func take() -> IOSurface? {
        let surface = pin()
        taken = surface != nil
        return surface
    }

    /// A downscaled picture of the frame, rendered off the main thread (hover cards); nil when the
    /// system reclaimed it.
    public func snapshot(maxPixelSize: CGFloat) async -> CGImage? {
        guard let surface = pin() else { return nil }
        defer { unpin() }
        let frame = SendableSurface(surface: surface)
        return await Task.detached(priority: .utility) {
            TerminalSnapshotRenderer.render(frame, maxPixelSize: maxPixelSize)
        }.value
    }

    /// The frame made non-volatile for one reader; nil (and volatile again) when the system
    /// reclaimed it.
    private func pin() -> IOSurface? {
        guard !purged else { return nil }
        var old = IOSurfacePurgeabilityState.nonVolatile
        surface.setPurgeable(.nonVolatile, oldState: &old)
        guard old != .empty else {
            purged = true
            surface.setPurgeable(.volatile, oldState: nil)
            return nil
        }
        pins += 1
        return surface
    }

    private func unpin() {
        pins -= 1
        if pins == 0, !taken { surface.setPurgeable(.volatile, oldState: nil) }
    }
}
