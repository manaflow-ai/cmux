import CmuxNextCompat
public import CoreGraphics
import IOSurface

/// An evicted terminal's last presented frame (cx-8w027.10 item b). The warm set closes a hidden
/// terminal's surface; its last IOSurface stays, volatile (CmuxNextCompat's `IOSurface.makeVolatile()`), so the
/// terminal shows that frame at once when it is shown again, until its fresh surface draws the
/// replay (``TerminalSession/showLastFrame(_:)``), and the hover card pictures it on demand. No
/// copy, no readback. A frame the system purged shows nothing: the pane attaches as before.
@MainActor
public final class TerminalLastFrame {
    /// What the frame tells the store that keeps it (``TerminalLastFrames``), so the store's
    /// counters follow the pages without a walk.
    enum Event {
        /// A reader or a new surface made the pages non-volatile.
        case becameNonVolatile
        /// The last reader ended: the pages are volatile again.
        case becameVolatile
        /// A reader found the pages purged: the frame shows nothing from now on.
        case purged
    }

    private let surface: IOSurface
    /// Readers that need the pages now (hover card renders); the frame is volatile only while none
    /// holds it and no new surface took it.
    private var pins = 0
    private var taken = false
    /// The system purged the pages (a reader found them empty): the frame shows nothing.
    public private(set) var isPurged = false
    /// The bytes of the frame's pages (the IOSurface allocation).
    public let bytes: Int
    /// The store that keeps the frame listens here; nil once the frame left it.
    var onEvent: (@MainActor (Event) -> Void)?

    /// The frame `session` presents now; nil before its first draw.
    public convenience init?(of session: TerminalSession) {
        self.init(presentedBy: session.surfaceView.frameSource)
    }

    /// The frame `source`'s renderer presents now, a reference to its IOSurface that outlives the
    /// surface (Ghostty keeps a released drawable's pixels while another owner holds it); nil before
    /// its first draw.
    convenience init?(presentedBy source: some TerminalFrameSource) {
        guard let surface = source.presentedFrame else { return nil }
        self.init(surface: surface)
    }

    /// Keeps `surface` as a last frame and makes its pages volatile (tests pass their own surface).
    init(surface: IOSurface) {
        self.surface = surface
        bytes = surface.allocationSize
        surface.makeVolatile()
    }

    /// Whether the pages are volatile now: no reader holds them and no new surface took them.
    /// Volatile pages are outside the process's physical footprint; the kernel takes them first.
    public var isVolatile: Bool { pins == 0 && !taken }

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
        return await Task.detached(priority: Task.currentPriority) {
            TerminalSnapshotRenderer.render(frame, maxPixelSize: maxPixelSize)
        }.value
    }

    private func pin() -> IOSurface? {
        guard !isPurged else { return nil }
        let wasVolatile = isVolatile
        guard surface.reclaim() else {
            // The reclaim made the empty surface non-volatile: it goes back, so it never counts.
            surface.makeVolatile()
            isPurged = true
            onEvent?(.purged)
            return nil
        }
        pins += 1
        if wasVolatile { onEvent?(.becameNonVolatile) }
        return surface
    }

    private func unpin() {
        pins -= 1
        guard isVolatile else { return }
        surface.makeVolatile()
        onEvent?(.becameVolatile)
    }
}
