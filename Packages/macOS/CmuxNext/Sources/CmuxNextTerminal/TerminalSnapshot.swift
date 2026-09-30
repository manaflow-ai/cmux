public import AppKit
import CoreImage
import IOSurface
import CmuxNextWakeups
import QuartzCore

// Hover previews. Ghostty's Metal renderer presents each frame by setting an
// IOSurface as this view's layer contents (renderer/metal/IOSurfaceLayer.zig),
// so the latest frame is always available without asking Ghostty to draw.
extension TerminalSurfaceView {
    /// The last presented frame, or nil before the first draw.
    var presentedFrame: IOSurface? {
        guard let contents = layer?.contents else { return nil }
        let object = contents as CFTypeRef
        guard CFGetTypeID(object) == IOSurfaceGetTypeID() else { return nil }
        return unsafeDowncast(object, to: IOSurface.self)
    }

    /// Downscaled copy of the last presented frame. One GPU blit; does not
    /// wake the renderer, so it is safe for surfaces that are occluded.
    func snapshot(maxPixelSize: CGFloat) -> CGImage? {
        guard let frame = presentedFrame else { return nil }
        return TerminalSnapshotRenderer.render(SendableSurface(surface: frame), maxPixelSize: maxPixelSize)
    }

    /// Like ``snapshot(maxPixelSize:)`` but renders off the main thread: the
    /// CoreImage render waits for the GPU (`waitUntilCompleted`), which
    /// stalled the main thread 60+ ms under load when a tab was hidden.
    func snapshotInBackground(maxPixelSize: CGFloat) async -> CGImage? {
        guard let frame = presentedFrame else { return nil }
        let surface = SendableSurface(surface: frame)
        return await Task.detached(priority: .utility) {
            TerminalSnapshotRenderer.render(surface, maxPixelSize: maxPixelSize)
        }.value
    }
}

/// An IOSurface handed to the snapshot renderer. IOSurfaces are safe to read
/// from any thread; the preview may show a frame Ghostty is replacing.
struct SendableSurface: @unchecked Sendable {
    let surface: IOSurface
}

enum TerminalSnapshotRenderer {
    static nonisolated(unsafe) let context = CIContext(options: [.cacheIntermediates: false, .name: "cmux-next.terminal.snapshot"])

    /// CIContext is thread-safe.
    nonisolated static func render(_ frame: SendableSurface, maxPixelSize: CGFloat) -> CGImage? {
        let image = CIImage(ioSurface: frame.surface)
        let extent = image.extent
        let longest = max(extent.width, extent.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxPixelSize / longest)
        let scaled = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
        // concurrency-allow: nonisolated; the App calls it through snapshotInBackground (a detached task).
        return context.createCGImage(scaled, from: scaled.extent.integral)
    }
}

/// Live, scaled mirror of a terminal (the terminal debug window only; hover
/// previews use snapshots).
///
/// Shares the source's presented IOSurface by pointer on every frame of its
/// window's FrameScheduler: no copy, no second Ghostty surface. It ticks
/// every frame while it is in a window (reviewed exception in
/// plans/cmux-next/idle-wakeups.md: a debug surface the user opens and closes). While a mirror is in a
/// window the source keeps rendering even if it is hidden or suspended, so
/// the preview of a background tab stays live. Remove the mirror from its
/// window when the preview closes.
public final class TerminalMirrorView: NSView {
    private weak var session: TerminalSession?
    private var holdsDemand = false
    private lazy var frames = FrameClient(owner: "TerminalMirror.debug", view: self) { [weak self] _ in
        self?.copyFrame()
        return self != nil
    }

    init(session: TerminalSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resizeAspect
        layer?.masksToBounds = true
        layer?.backgroundColor = GhosttyRuntime.shared.backgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        if holdsDemand { session?.mirrorDemand -= 1 }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setActive(window != nil)
    }

    private func setActive(_ active: Bool) {
        if active, !holdsDemand {
            holdsDemand = true
            session?.mirrorDemand += 1
            frames.activate()
            copyFrame()
        } else if !active, holdsDemand {
            holdsDemand = false
            session?.mirrorDemand -= 1
            frames.deactivate()
        }
    }

    private func copyFrame() {
        guard let frame = session?.surfaceView.presentedFrame, let layer else { return }
        if let current = layer.contents, (current as CFTypeRef) === (frame as CFTypeRef) { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = frame
        CATransaction.commit()
    }
}
