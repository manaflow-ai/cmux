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

    /// The frame `session` presents now; nil before its first draw.
    public init?(of session: TerminalSession) {
        guard let surface = session.surfaceView.presentedFrame else { return nil }
        self.surface = surface
        var old: UInt32 = 0
        IOSurfaceSetPurgeable(surface, UInt32(kIOSurfacePurgeableVolatile), &old)
    }

    /// The frame, made non-volatile again for its new owner; nil when the system reclaimed it.
    func take() -> IOSurface? {
        var old: UInt32 = 0
        IOSurfaceSetPurgeable(surface, UInt32(kIOSurfacePurgeableNonVolatile), &old)
        return old == UInt32(kIOSurfacePurgeableEmpty) ? nil : surface
    }

    /// A downscaled picture of the frame, rendered off the main thread (hover cards); nil when the
    /// system reclaimed it.
    public func snapshot(maxPixelSize: CGFloat) async -> CGImage? {
        guard let surface = take() else { return nil }
        let frame = SendableSurface(surface: surface)
        let image = await Task.detached(priority: .utility) {
            TerminalSnapshotRenderer.render(frame, maxPixelSize: maxPixelSize)
        }.value
        var old: UInt32 = 0
        IOSurfaceSetPurgeable(surface, UInt32(kIOSurfacePurgeableVolatile), &old)
        return image
    }
}
