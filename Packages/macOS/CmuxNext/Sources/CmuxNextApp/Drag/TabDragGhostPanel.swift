import AppKit
import CmuxNextBridge
import CmuxNextWakeups
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
    private let tabSize: CGSize
    /// Where the pointer holds the tab (y up, in a `tabSize` tab); the
    /// ghost scales about that point.
    private let grabOffset: CGPoint
    /// Shadow room and thumbnail inset, read once per drag (the panel's
    /// size depends on them).
    private let pad: CGFloat
    private let inset: CGFloat

    init(tabImage: CGImage?, tabSize: CGSize, grabOffset: CGPoint, aspect: CGFloat?, scale: CGFloat) {
        self.tabSize = tabSize
        self.grabOffset = grabOffset
        let pad = DragTunables.ghostPanelPad.value
        let inset = DragTunables.ghostCardInset.value
        self.pad = pad
        self.inset = inset
        cardSize = TabDragGeometry.cardSize(tabSize: tabSize, aspect: aspect, inset: inset)
        panelSize = CGSize(width: max(cardSize.width, tabSize.width * 1.6, 320) + pad * 2,
                           height: max(cardSize.height, tabSize.height * 1.6) + pad * 2)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        // A drag can cross windows of different rooms; the ghost keeps the
        // app theme (Ghostty config).
        ThemeScope.app.adopt(panel)
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
        thumbLayer.cornerRadius = Metrics.panelCornerRadius - inset
        thumbLayer.cornerCurve = .continuous
        thumbLayer.opacity = 0
        thumbLayer.contentsScale = scale
        overlay.addSublayer(thumbLayer)
        tabLayer.contents = tabImage
        tabLayer.contentsGravity = .resize
        tabLayer.contentsScale = scale
        tabLayer.shadowColor = ThemeScope.app.perform { Palette.shadow.cgColor }
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

    /// A frame client of the ghost panel's own FrameScheduler (its screen,
    /// 120 Hz on ProMotion).
    func makeFrameClient(owner: String, onFrame: @escaping @MainActor (FrameTick) -> Bool) -> FrameClient {
        FrameClient(owner: owner, view: root, onFrame: onFrame)
    }

    /// The ghost's screen geometry for `motion`.
    func layout(_ motion: TabDragGhostMotion) -> TabDragGhostLayout {
        TabDragGhostLayout(motion: motion, cardSize: cardSize, inset: inset, grabOffset: grabOffset, tabSize: tabSize)
    }

    /// Lays the panel and its layers out for one motion frame
    /// (`TabDragGhostLayout`): the card unfolds around the tab image, which
    /// never moves under the pointer, and a shrink pivots on the grabbed
    /// point.
    func render(_ motion: TabDragGhostMotion) {
        let layout = layout(motion)
        let tab = layout.tab
        let c = layout.cardness
        let origin = CGPoint(x: (tab.minX - pad).rounded(), y: (tab.maxY + pad - panelSize.height).rounded())
        panel.setFrameOrigin(origin)
        panel.alphaValue = motion.presentedOpacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let tabLocal = tab.offsetBy(dx: -origin.x, dy: -origin.y)
        let current = layout.card.offsetBy(dx: -origin.x, dy: -origin.y)
        glass.frame = current
        glass.alphaValue = c
        let thumbHeight = max(0, current.height - tab.height - inset * 3)
        thumbLayer.frame = CGRect(x: current.minX + inset, y: current.minY + inset,
                                  width: max(0, current.width - inset * 2), height: thumbHeight)
        thumbLayer.opacity = Float(c)
        tabLayer.frame = tabLocal
        tabLayer.shadowOpacity = Float(0.28 * (1 - c))
        let s = layout.scale
        if s != 1 {
            // The root layer's anchor is (0, 0) (AppKit), so the pivot is explicit.
            let pivot = CGPoint(x: layout.pivot.x - origin.x, y: layout.pivot.y - origin.y)
            var transform = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
            transform = CATransform3DScale(transform, s, s, 1)
            transform = CATransform3DTranslate(transform, -pivot.x, -pivot.y, 0)
            root.layer?.sublayerTransform = transform
        } else {
            root.layer?.sublayerTransform = CATransform3DIdentity
        }
        CATransaction.commit()
    }
}

/// Layer-backed root that never takes the mouse.
private final class GhostRootView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
