package import AppKit
package import CmuxNextWakeups
package import CmuxNextDesign
import QuartzCore
package import CmuxNextTabs

/// The drag ghost: one borderless, non-activating panel that ignores the
/// mouse and floats above every window. It draws the dragged tab's image
/// and, as `cardness` rises, unfolds a Liquid Glass preview card under it
/// with a live content thumbnail (terminal or browser snapshot). Over a
/// strip the card folds back into an inline tab. In a translucent window the
/// tab image has no card of its own (`WindowBackdrop.dragsOnGlass`): the glass is under it from
/// the first frame, shaped like the tab until the card unfolds, so a picked-up
/// tab stays glass instead of turning into a solid theme block.
///
/// The panel has a fixed size (the largest card plus shadow room) and only
/// moves, so a frame costs one window move and a few layer frames.
package final class TabDragGhostPanel {
    package let panel: NSPanel
    private let root: GhostRootView
    private let glass: GlassPanelView
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
    /// The tab image stands on the glass (a translucent window): the glass shows at every
    /// cardness, and the glass edge, not a shadow, lifts it. A theme change can turn it.
    package private(set) var onGlass: Bool
    /// The strip the dragged tab came from and the tab: on a theme change (a light/dark switch
    /// mid-drag) the ghost draws the tab again in that strip's theme (`TabStripView.dragImage`),
    /// instead of keeping the colors of the moment it was picked up. Nil for a group drag, whose
    /// image stays as picked up.
    private weak var source: TabStripView?
    private let sourceTab: TabID?
    /// The last frame `render` drew, drawn again after a theme change (a still pointer sends no frame).
    private var lastMotion: TabDragGhostMotion?

    /// - Parameter onGlass: The image was rendered without a card (`WindowBackdrop.dragCardFill`)
    ///   in the scope it was lifted from, not the app's: a workspace can pin its own background.
    /// - Parameter source: The strip a single dragged tab (`payload` `.tab`) came from; the ghost
    ///   follows its theme. Nil, or a group payload, keeps the picked-up image.
    package init(tabImage: CGImage?, tabSize: CGSize, grabOffset: CGPoint, aspect: CGFloat?, scale: CGFloat, onGlass: Bool,
                 source: TabStripView? = nil, payload: TabDragPayload? = nil) {
        self.onGlass = onGlass
        self.source = source
        if case .tab(let id, _) = payload { sourceTab = TabID(id) } else { sourceTab = nil }
        self.tabSize = tabSize
        self.grabOffset = grabOffset
        pad = DragTunables.ghostPanelPad.value
        inset = DragTunables.ghostCardInset.value
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
        // The ghost is the whole content of a clear panel: before Liquid
        // Glass the card blurs the desktop under it.
        glass.samplesBehindWindow = true
        glass.alphaValue = onGlass ? 1 : 0
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
        // The raised elevation step (PopupStyle.elevation2): a tight lift, not a dark halo.
        tabLayer.shadowOpacity = onGlass ? 0 : Float(PopupStyle.elevation2.alpha)
        tabLayer.shadowRadius = PopupStyle.elevation2.layerRadius
        tabLayer.shadowOffset = PopupStyle.elevation2.layerOffset()
        overlay.addSublayer(tabLayer)
        panel.contentView = root
        ThemeScope.app.addResponder(self)
        if let scope = source?.themeScope, scope !== ThemeScope.app { scope.addResponder(self) }
    }

    /// The live content preview, when the snapshot arrives.
    package func setThumbnail(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbLayer.contents = image
        CATransaction.commit()
    }

    package func show() {
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    package func close() {
        panel.orderOut(nil)
        ThemeScope.app.removeResponder(self)
        source?.themeScope.removeResponder(self)
    }

    /// A frame client of the ghost panel's own FrameScheduler (its screen,
    /// 120 Hz on ProMotion).
    /// `settle` lands the ghost when its panel goes out of sight (FrameScheduler gives it no frames).
    package func makeFrameClient(owner: String, settle: @escaping @MainActor () -> Void,
                         onFrame: @escaping @MainActor (FrameTick) -> Bool) -> FrameClient {
        FrameClient(owner: owner, scheduler: { [weak root] in root.map(FrameScheduler.forView) ?? .app }, settle: settle,
                    onFrame: onFrame)
    }

    /// The ghost's screen geometry for `motion`.
    package func layout(_ motion: TabDragGhostMotion) -> TabDragGhostLayout {
        TabDragGhostLayout(motion: motion, cardSize: cardSize, inset: inset, grabOffset: grabOffset, tabSize: tabSize)
    }

    /// Lays the panel and its layers out for one motion frame
    /// (`TabDragGhostLayout`): the card unfolds around the tab image, which
    /// never moves under the pointer, and a shrink pivots on the grabbed
    /// point.
    package func render(_ motion: TabDragGhostMotion) {
        lastMotion = motion
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
        glass.alphaValue = onGlass ? 1 : c
        let thumbHeight = max(0, current.height - tab.height - inset * 3)
        thumbLayer.frame = CGRect(x: current.minX + inset, y: current.minY + inset,
                                  width: max(0, current.width - inset * 2), height: thumbHeight)
        thumbLayer.opacity = Float(c)
        tabLayer.frame = tabLocal
        tabLayer.shadowOpacity = onGlass ? 0 : Float(PopupStyle.elevation2.alpha * (1 - c))
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

extension TabDragGhostPanel: ThemeResponsive {
    /// The theme changed mid-drag: the tab is drawn again in its strip's theme, and the shadow
    /// and glass tint take the app's new colors, at once (a theme switch never animates a drag).
    package func themeDidChange() {
        let fresh = sourceTab.flatMap { id in source?.dragImage(of: id, size: tabSize) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let fresh, let image = fresh.image?.cgImage {
            tabLayer.contents = image
            onGlass = fresh.onGlass
        }
        ThemeScope.app.perform {
            tabLayer.shadowColor = Palette.shadow.cgColor
            glass.tintColor = GlassLevel.chrome.tint(Palette.glassTint)
        }
        CATransaction.commit()
        if let lastMotion { render(lastMotion) }
    }
}

/// Layer-backed root that never takes the mouse.
private final class GhostRootView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
