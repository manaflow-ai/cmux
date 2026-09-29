public import AppKit
import CoreImage
import IOSurface
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
        let image = CIImage(ioSurface: frame)
        let extent = image.extent
        let longest = max(extent.width, extent.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxPixelSize / longest)
        let scaled = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
        return TerminalSnapshotRenderer.context.createCGImage(scaled, from: scaled.integralExtent)
    }
}

enum TerminalSnapshotRenderer {
    static let context = CIContext(options: [.cacheIntermediates: false, .name: "cmux-next.terminal.snapshot"])
}

private extension CIImage {
    var integralExtent: CGRect { extent.integral }
}

/// Live, scaled mirror of a terminal for tab hover previews.
///
/// Shares the source's presented IOSurface by pointer on every display
/// refresh: no copy, no second Ghostty surface. While a mirror is in a
/// window the source keeps rendering even if it is hidden or suspended, so
/// the preview of a background tab stays live. Remove the mirror from its
/// window when the preview closes.
public final class TerminalMirrorView: NSView {
    private weak var session: TerminalSession?
    private var link: CADisplayLink?
    private var holdsDemand = false

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
        link?.invalidate()
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
            let link = displayLink(target: self, selector: #selector(refresh(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            copyFrame()
        } else if !active, holdsDemand {
            holdsDemand = false
            session?.mirrorDemand -= 1
            link?.invalidate()
            link = nil
        }
    }

    @objc private func refresh(_ link: CADisplayLink) {
        copyFrame()
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
