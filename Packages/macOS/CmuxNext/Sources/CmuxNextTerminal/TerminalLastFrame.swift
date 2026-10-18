public import CoreGraphics
import IOSurface

/// An evicted terminal's last presented frame (cx-8w027.10 item b). The warm set closes a hidden
/// terminal's surface; its last IOSurface stays, so the terminal shows that frame at once when it
/// is shown again, until its fresh surface draws the replay (``TerminalSession/showLastFrame(_:)``),
/// and the hover card pictures it on demand. No copy, no readback. The app bounds how many it keeps
/// (`TerminalLastFrames`); memory pressure lowers that bound with the warm set's.
@MainActor
public final class TerminalLastFrame {
    let surface: IOSurface

    /// The frame `session` presents now; nil before its first draw.
    public init?(of session: TerminalSession) {
        guard let surface = session.surfaceView.presentedFrame else { return nil }
        self.surface = surface
    }

    /// A downscaled picture of the frame, rendered off the main thread (hover cards).
    public func snapshot(maxPixelSize: CGFloat) async -> CGImage? {
        let frame = SendableSurface(surface: surface)
        return await Task.detached(priority: .utility) {
            TerminalSnapshotRenderer.render(frame, maxPixelSize: maxPixelSize)
        }.value
    }
}
