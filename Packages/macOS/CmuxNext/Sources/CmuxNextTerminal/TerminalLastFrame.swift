public import CoreGraphics
import IOSurface

/// An evicted terminal's last presented frame (cx-8w027.10 item b). The warm set closes a hidden
/// terminal's surface; its last IOSurface stays, volatile (``TerminalFramePurgeability``), so the
/// terminal shows that frame at once when it is shown again, until its fresh surface draws the
/// replay (``TerminalSession/showLastFrame(_:)``), and the hover card pictures it on demand. No
/// copy, no readback. A frame the system purged shows nothing: the pane attaches as before.
@MainActor
public final class TerminalLastFrame {
    private let surface: IOSurface
    /// Readers that need the pages now (hover card renders); the frame is volatile only while none
    /// holds it and no new surface took it.
    private var pins = 0
    private var taken = false
    private var purged = false

    /// The frame `session` presents now; nil before its first draw.
    public init?(of session: TerminalSession) {
        guard let surface = session.surfaceView.presentedFrame else { return nil }
        self.surface = surface
        surface.makeVolatile()
    }

    /// The frame for a new surface that shows it from now on (non-volatile for good); nil when the
    /// system purged it.
    func take() -> IOSurface? {
        guard let surface = pin() else { return nil }
        taken = true
        return surface
    }

    /// A downscaled picture of the frame, rendered off the main thread (hover cards); nil when the
    /// system purged it.
    public func snapshot(maxPixelSize: CGFloat) async -> CGImage? {
        guard let surface = pin() else { return nil }
        defer { unpin() }
        let frame = SendableSurface(surface: surface)
        return await Task.detached(priority: .utility) {
            TerminalSnapshotRenderer.render(frame, maxPixelSize: maxPixelSize)
        }.value
    }

    private func pin() -> IOSurface? {
        guard !purged else { return nil }
        guard surface.reclaim() else {
            purged = true
            return nil
        }
        pins += 1
        return surface
    }

    private func unpin() {
        pins -= 1
        if pins == 0, !taken { surface.makeVolatile() }
    }
}
