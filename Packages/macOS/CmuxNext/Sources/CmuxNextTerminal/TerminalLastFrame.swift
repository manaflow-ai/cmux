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
        surface.setPurgeable(IOSurface.volatile)
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
        guard surface.setPurgeable(IOSurface.nonVolatile) != IOSurface.empty else {
            purged = true
            surface.setPurgeable(IOSurface.volatile)
            return nil
        }
        pins += 1
        return surface
    }

    private func unpin() {
        pins -= 1
        if pins == 0, !taken { surface.setPurgeable(IOSurface.volatile) }
    }
}

/// kIOSurfacePurgeable* states by value (IOSurfaceTypes.h: NonVolatile 0, Volatile 1, Empty 2):
/// the imported Swift names differ between SDKs.
private extension IOSurface {
    static let nonVolatile: UInt32 = 0
    static let volatile: UInt32 = 1
    static let empty: UInt32 = 2

    /// Sets the purgeable state; returns the state before.
    @discardableResult
    func setPurgeable(_ state: UInt32) -> UInt32 {
        var old: UInt32 = 0
        IOSurfaceSetPurgeable(self, state, &old)
        return old
    }
}
