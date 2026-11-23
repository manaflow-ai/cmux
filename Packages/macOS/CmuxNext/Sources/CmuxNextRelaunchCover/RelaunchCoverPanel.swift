import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens

/// One window's last picture: borderless, click-through, shadowed like the window it stands in for. Each pane's
/// region is its own layer so it can fade alone (progressive); the rest (sidebar, bars, chrome) is the picture
/// with those regions cut out.
@MainActor
final class RelaunchCoverPanel: NSWindow {
    private var surfaceLayers: [String: CALayer] = [:]

    init(frame: CGRect, image: CGImage, surfaces: [RelaunchCoverSurface]) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        contentView = view
        guard let root = view.layer else { return }
        let size = frame.size
        // Top-left surface rects to the layer's bottom-left space; contentsRect is in the same unit space.
        let rects = surfaces.map { surface -> (String, CGRect) in
            let r = surface.rect.rect
            return (surface.id, CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height))
        }
        let chrome = CALayer()
        chrome.frame = root.bounds
        chrome.contents = image
        chrome.contentsGravity = .resize
        let mask = CAShapeLayer()
        let path = CGMutablePath()
        path.addRect(root.bounds)
        for (_, rect) in rects { path.addRect(rect) }
        mask.path = path
        mask.fillRule = .evenOdd
        chrome.mask = mask
        root.addSublayer(chrome)
        for (id, rect) in rects {
            let layer = CALayer()
            layer.frame = rect
            layer.contents = image
            layer.contentsGravity = .resize
            layer.contentsRect = CGRect(x: rect.minX / size.width, y: rect.minY / size.height,
                                        width: rect.width / size.width, height: rect.height / size.height)
            root.addSublayer(layer)
            surfaceLayers[id] = layer
        }
    }

    /// Fades this pane's region out (`fades`), or removes it in one frame.
    func fadeSurface(_ id: String, fades: Bool) {
        guard let layer = surfaceLayers.removeValue(forKey: id) else { return }
        Motion.panes.transaction(fades ? .crossfade : nil) { layer.opacity = 0 }
    }

    /// Fades what is left out (`fades`), or removes it in one frame, then closes.
    func fadeOut(fades: Bool) {
        let done: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            parent?.removeChildWindow(self)
            orderOut(nil)
            close()
        }
        guard fades, let view = contentView else { return done() }
        Motion.panes.animate(.crossfade, in: view, { animator().alphaValue = 0 }, completion: done)
    }
}
