import AppKit
import CmuxNextBridge
import CmuxNextDesign
import QuartzCore

/// The drag ghost: one borderless, non-activating panel that ignores the
/// mouse and floats above every window. It draws the dragged tab's image
/// and, as `cardness` rises, unfolds a Liquid Glass preview card under it
/// with a live content thumbnail (terminal or browser snapshot). Over a
/// strip the card folds back into an inline tab.
///
/// The panel has a fixed size (the largest card plus shadow room) and only
/// moves, so a frame costs one window move and a few layer frames.
final class TabDragGhostPanel {
    let panel: NSPanel
    private let root: GhostRootView
    private let glass: NSGlassEffectView
    private let tabLayer = CALayer()
    private let thumbLayer = CALayer()
    private let cardSize: CGSize
    private let panelSize: CGSize
    static let pad: CGFloat = 32
    static let inset: CGFloat = 6

    init(tabImage: CGImage?, tabSize: CGSize, aspect: CGFloat?, scale: CGFloat) {
        cardSize = TabDragGeometry.cardSize(tabSize: tabSize, aspect: aspect, inset: Self.inset)
        panelSize = CGSize(width: max(cardSize.width, tabSize.width * 1.6, 320) + Self.pad * 2,
                           height: max(cardSize.height, tabSize.height * 1.6) + Self.pad * 2)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        root = GhostRootView(frame: NSRect(origin: .zero, size: panelSize))
        root.wantsLayer = true
        glass = Glass.makePanel(style: .regular, cornerRadius: Metrics.panelCornerRadius)
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.alphaValue = 0
        root.addSubview(glass)

        let overlay = CALayer()
        overlay.frame = root.bounds
        overlay.zPosition = 1
        root.layer?.addSublayer(overlay)
        thumbLayer.contentsGravity = .resizeAspectFill
        thumbLayer.masksToBounds = true
        thumbLayer.cornerRadius = Metrics.panelCornerRadius - Self.inset
        thumbLayer.cornerCurve = .continuous
        thumbLayer.opacity = 0
        thumbLayer.contentsScale = scale
        overlay.addSublayer(thumbLayer)
        tabLayer.contents = tabImage
        tabLayer.contentsGravity = .resize
        tabLayer.contentsScale = scale
        tabLayer.shadowColor = NSColor.black.cgColor
        tabLayer.shadowOpacity = 0.28
        tabLayer.shadowRadius = 10
        tabLayer.shadowOffset = CGSize(width: 0, height: -3)
        overlay.addSublayer(tabLayer)
        panel.contentView = root
    }

    /// The live content preview, when the snapshot arrives.
    func setThumbnail(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbLayer.contents = image
        CATransaction.commit()
    }

    func show() {
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func close() {
        panel.orderOut(nil)
    }

    /// A display link on the ghost's own screen (120 Hz on ProMotion).
    func makeDisplayLink(target: Any, selector: Selector) -> CADisplayLink {
        root.displayLink(target: target, selector: selector)
    }

    /// Lays the panel and its layers out for one motion frame.
    func render(_ motion: TabDragGhostMotion) {
        let tab = motion.presentedRect
        let c = motion.presentedCardness
        let origin = CGPoint(x: (tab.minX - Self.pad).rounded(), y: (tab.maxY + Self.pad - panelSize.height).rounded())
        panel.setFrameOrigin(origin)
        panel.alphaValue = motion.presentedOpacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let tabLocal = CGRect(x: tab.minX - origin.x, y: tab.minY - origin.y, width: tab.width, height: tab.height)
        let card = CGRect(x: tabLocal.minX - Self.inset, y: tabLocal.maxY + Self.inset - cardSize.height,
                          width: cardSize.width, height: cardSize.height)
        let current = Self.lerp(tabLocal, card, c)
        glass.frame = current
        glass.alphaValue = c
        let thumbHeight = max(0, current.height - tab.height - Self.inset * 3)
        thumbLayer.frame = CGRect(x: current.minX + Self.inset, y: current.minY + Self.inset,
                                  width: max(0, current.width - Self.inset * 2), height: thumbHeight)
        thumbLayer.opacity = Float(c)
        tabLayer.frame = tabLocal
        tabLayer.shadowOpacity = Float(0.28 * (1 - c))
        let s = motion.presentedScale
        if s != 1 {
            let center = CGPoint(x: current.midX, y: current.midY)
            var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
            transform = CATransform3DScale(transform, s, s, 1)
            transform = CATransform3DTranslate(transform, -center.x, -center.y, 0)
            root.layer?.sublayerTransform = transform
        } else {
            root.layer?.sublayerTransform = CATransform3DIdentity
        }
        CATransaction.commit()
    }

    private static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }
}

/// Layer-backed root that never takes the mouse.
private final class GhostRootView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
