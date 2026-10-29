import AppKit
import CmuxNextBridge
import CmuxNextWakeups
import CmuxNextDesign
import QuartzCore
import CmuxNextTabs

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
///
/// With `motion.renderServer` on (``rendersOnServer``) the ghost follows Chrome's tab drag
/// (chrome/browser/ui/views/tabs/tab_drag_controller.cc: an attached drag moves the tab views in the
/// source widget; only a detached one gets its own window). Inside the source window it is a view in
/// that window's overlay host, moved per pointer event with no window call; the panel shows it only
/// outside. No frame client steps it: Core Animation runs its springs (``present(_:token:holds:landing:)``).
final class TabDragGhostPanel {
    let panel: NSPanel
    let root: NSView
    private let glass: GlassPanelView
    /// Render server only: the card's rounded shape and hairline edge. Its frame springs while the
    /// glass inside it stays still (the size of the root), so the card unfolds with no glass
    /// relayout and the clip culls the blur to the card.
    private var cardClip: TabDragGhostRootView?
    /// Render server only: the panel's content, holding the root while the ghost is outside.
    private var panelContainer: TabDragGhostRootView?
    /// Render server only: what the source window's overlay presents, the root inside it.
    private let carrier = TabDragGhostRootView(frame: .zero)
    let tabLayer = CALayer()
    let thumbLayer = CALayer()
    private let cardSize: CGSize
    let panelSize: CGSize
    private let tabSize: CGSize
    /// Where the pointer holds the tab (y up, in a `tabSize` tab); the ghost scales about that point.
    private let grabOffset: CGPoint
    /// Shadow room and thumbnail inset, read once per drag (the panel's size depends on them).
    let pad: CGFloat
    let inset: CGFloat
    /// The tab image stands on the glass (a translucent window): the glass shows at every
    /// cardness, and the glass edge, not a shadow, lifts it.
    let onGlass: Bool
    /// `motion.renderServer`: ``present(_:token:holds:landing:)``, not ``render(_:)`` per frame.
    let rendersOnServer: Bool
    /// The window the drag started in: its overlay holds the ghost while it fits there.
    weak var sourceWindow: NSWindow?
    /// Where the ghost shows: the drag panel (outside the source window) or the source window's
    /// overlay host (``carrier``).
    private enum Host {
        case hidden, panel, window(OverlayHandle)
        var isHidden: Bool { if case .hidden = self { true } else { false } }
    }

    /// Where the ghost shows, the rest it was laid out at last and the motion's jumps then (render server).
    private var host: Host = .hidden
    var shown: TabDragGhostRest?
    var shownJumps = 0
    /// The ghost lands: it stays in its host until it closes.
    var pinsHost = false
    /// A render-server call landed at rest (only the newest call can: ``RenderSpring``).
    var onRest: (() -> Void)?
    /// Every spring of the render server landed (the newest call's landing).
    private(set) var isAtRest = true
    /// Where the ghost may still draw while its springs run; a host holds it only with this room.
    private(set) var flight = TabDragGhostFlight()
    /// ``close()`` ran: nothing shows the ghost again (a late preview or daemon echo).
    private(set) var isClosed = false

    /// - Parameters:
    ///   - onGlass: The image was rendered without a card (`WindowBackdrop.dragCardFill`)
    ///     in the scope it was lifted from, not the app's: a workspace can pin its own background.
    ///   - sourceWindow: The window the drag started in (render server: the ghost shows in its overlay).
    ///   - rendersOnServer: `motion.renderServer`, read once for the drag.
    init(tabImage: CGImage?, tabSize: CGSize, grabOffset: CGPoint, aspect: CGFloat?, scale: CGFloat, onGlass: Bool,
         sourceWindow: NSWindow? = nil, rendersOnServer: Bool = false) {
        self.onGlass = onGlass
        self.rendersOnServer = rendersOnServer
        self.sourceWindow = sourceWindow
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

        root = TabDragGhostRootView(frame: NSRect(origin: .zero, size: panelSize))
        root.wantsLayer = true
        // On the render server the card clip has the corners (the glass fills the root).
        glass = Glass.makePanel(style: .regular, cornerRadius: rendersOnServer ? 0 : Metrics.panelCornerRadius)
        glass.translatesAutoresizingMaskIntoConstraints = true
        // The ghost is the whole content of a clear panel (or of the window's
        // clear overlay panel): before Liquid Glass the card blurs what is under it.
        glass.samplesBehindWindow = true
        if rendersOnServer {
            // The clip gives the card its shape and edge (the hairline `GlassPanelView` draws at its own
            // bounds, which here are the root's); its border draws above the glass.
            let clip = TabDragGhostRootView(frame: .zero)
            clip.wantsLayer = true
            clip.clipsToBounds = true
            clip.layer?.masksToBounds = true
            clip.layer?.cornerRadius = Metrics.panelCornerRadius
            clip.layer?.cornerCurve = .continuous
            clip.layer?.borderWidth = Metrics.lineWidth(1 / max(scale, 1))
            clip.layer?.borderColor = ThemeScope.app.perform { Palette.separator.cgColor }
            clip.alphaValue = onGlass ? 1 : 0
            glass.frame = root.bounds
            clip.addSubview(glass)
            root.addSubview(clip)
            cardClip = clip
        } else {
            glass.alphaValue = onGlass ? 1 : 0
            root.addSubview(glass)
        }

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
        // shadow: alpha-derived: the image's alpha is the shape (a tab or chip pill, a sidebar row, a
        // multi-tab strip; none for a row handed off with no image), and the layer has no sublayers, so
        // only its own contents are read.
        // The raised elevation step (PopupStyle.elevation2): a tight lift, not a dark halo.
        tabLayer.shadowOpacity = onGlass ? 0 : Float(PopupStyle.elevation2.alpha)
        tabLayer.shadowRadius = PopupStyle.elevation2.layerRadius
        tabLayer.shadowOffset = PopupStyle.elevation2.layerOffset()
        overlay.addSublayer(tabLayer)
        if rendersOnServer {
            // The root moves between this panel and the source window's overlay; it keeps the app
            // theme in both.
            root.appearance = panel.appearance
            let container = TabDragGhostRootView(frame: root.frame)
            container.wantsLayer = true
            container.autoresizingMask = [.width, .height]
            container.addSubview(root)
            panel.contentView = container
            panelContainer = container
            carrier.wantsLayer = true
            carrier.clipsToBounds = false
        } else {
            panel.contentView = root
        }
    }

    /// The live content preview, when the snapshot arrives.
    func setThumbnail(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbLayer.contents = image
        CATransaction.commit()
    }

    /// Shows the panel (CPU path; on the render server `present` places the ghost).
    func show() {
        guard !rendersOnServer else { return }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func close() {
        isClosed = true
        onRest = nil
        leaveHost()
        panel.orderOut(nil)
    }

    /// A frame client of the ghost's own FrameScheduler (its screen, 120 Hz
    /// on ProMotion).
    func makeFrameClient(owner: String, onFrame: @escaping @MainActor (FrameTick) -> Bool) -> FrameClient {
        // The CPU ghost's spring (render-server ghost off) ticks for the drag; on the render server only these wake it.
        // input-driven: a tab drag's edge autoscroll and the dwell while the pointer rests (TabDragSession.wake)
        FrameClient(owner: owner, rate: .motion, view: root, onFrame: onFrame)
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

// MARK: Render server

/// The ghost on the render server: additive springs keep the presented
/// value and velocity continuous on a retarget (cc/animation/scroll_offset_animation_curve.cc `UpdateTarget`).
extension TabDragGhostPanel {
    /// The overlay host keeps an overlay this far inside the window (`WindowOverlayHost.origin`):
    /// the carrier sits there, and the root inside it anywhere, since the carrier does not clip.
    static let overlayInset: CGFloat = 8

    /// The rest of `motion`.
    func rest(_ motion: TabDragGhostMotion) -> TabDragGhostRest {
        let settled = motion.rest
        return TabDragGhostRest(layout: layout(settled), opacity: settled.presentedOpacity, rootSize: panelSize, pad: pad, inset: inset,
                                onGlass: onGlass, shadowAlpha: PopupStyle.elevation2.alpha)
    }

    /// Shows `motion` at rest, laid out once. A pointer move only moves the root in its host; a jump
    /// (``TabDragGhostMotion/jumpCount``), a morph or the landing is one spring group of `token` from
    /// what showed. `holds` answers whether the source window shows a screen rect in front of every
    /// other window (nil: it shows none); its overlay holds the ghost only then. `landing`: the ghost
    /// keeps its host and ``onRest`` runs when it settles. A closed ghost shows nothing.
    func present(_ motion: TabDragGhostMotion, token: MotionSpring, holds: ((CGRect) -> Bool)?, landing: Bool = false) {
        guard !isClosed else { return }
        let next = rest(motion)
        let previous = shown
        let jumped = previous != nil && motion.jumpCount != shownJumps
        shownJumps = motion.jumpCount
        shown = next
        let shift = jumped ? previous.map { CGPoint(x: $0.origin.x - next.origin.x, y: $0.origin.y - next.origin.y) } ?? .zero : .zero
        let springs = previous.map { landing || jumped || !$0.sameInside(next) } ?? false
        if springs, let previous { flight.add(shift: shift, drawn: previous.glass.union(previous.tab)) }
        if pinsHost || landing, !host.isHidden {
            move(to: next.origin)
        } else {
            place(next.origin, in: sourceWindow.flatMap { holdsGhost(next, in: $0, holds: holds) ? $0 : nil })
        }
        pinsHost = pinsHost || landing
        guard let previous else { return lay(next, landing: landing) }
        guard springs else { return }
        spring(from: previous, to: next, shift: shift, velocity: jumped ? motion.jumpVelocity : .zero, token: token)
    }

    /// Whether the source `window`'s overlay can show `rest` and every flight still running: the
    /// window is on screen and in front of every other window over all of it. No margin around it:
    /// a tab's shadow at the window's own edge clips there like the strip's own tabs, so a top-row
    /// slot stays in the overlay.
    func holdsGhost(_ rest: TabDragGhostRest, in window: NSWindow, holds: ((CGRect) -> Bool)?) -> Bool {
        guard let holds, window.isVisible, !window.isMiniaturized else { return false }
        return holds(flight.reach(of: rest))
    }

    // MARK: Hosts

    /// Puts the root at the screen `origin` in the source window's overlay (`window`) or, with no
    /// window, in the panel. The root's running springs move with it.
    func place(_ origin: CGPoint, in window: NSWindow?) {
        if let window {
            if case .window = host { return move(to: origin) }
            leaveHost()
            let bounds = NSRect(origin: .zero, size: window.frame.size).insetBy(dx: Self.overlayInset, dy: Self.overlayInset)
            carrier.frame = bounds
            carrier.addSubview(root)
            host = .window(WindowOverlayHost.host(for: window).present(carrier, options: OverlayOptions(kind: .dragGhost, anchor: bounds)))
            return move(to: origin)
        }
        if case .panel = host { return move(to: origin) }
        leaveHost()
        panelContainer?.addSubview(root)
        host = .panel
        move(to: origin)
        panel.orderFrontRegardless()
    }

    /// Moves the root to the screen `origin` in its host. The panel holds the root and the room of
    /// every running flight (``TabDragGhostFlight``): a jump resizes it once, a follow only moves it.
    func move(to origin: CGPoint) {
        switch host {
        case .hidden: return
        case .window:
            guard let overlay = carrier.window else { return }
            let local = carrier.convert(overlay.convertPoint(fromScreen: origin), from: nil)
            if root.frame.origin != local { root.setFrameOrigin(local) }
        case .panel:
            let room = flight.widened(CGRect(origin: origin, size: panelSize))
            if panel.frame.size != room.size {
                panel.setFrame(room, display: false)
            } else if panel.frame.origin != room.origin {
                panel.setFrameOrigin(room.origin)
            }
            let local = CGPoint(x: origin.x - room.minX, y: origin.y - room.minY)
            if root.frame.origin != local { root.setFrameOrigin(local) }
        }
    }

    /// Takes the root out of its host; the panel leaves the screen.
    func leaveHost() {
        if case .window(let handle) = host { handle.dismiss() }
        if case .panel = host { panel.orderOut(nil) }
        if !host.isHidden { root.removeFromSuperview() }
        host = .hidden
    }

    // MARK: Layers

    /// The first rest, in one frame.
    func lay(_ rest: TabDragGhostRest, landing: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeCard(rest.glass, opacity: rest.glassOpacity)
        thumbLayer.frame = rest.thumb
        thumbLayer.opacity = Float(rest.thumbOpacity)
        tabLayer.frame = rest.tab
        tabLayer.opacity = Float(rest.tabOpacity)
        tabLayer.shadowOpacity = Float(rest.tabShadow)
        CATransaction.commit()
        if landing { onRest?() }
    }

    /// The card's clip at `rect` (root coordinates) and `opacity`; the glass in it stays on the root's bounds.
    func placeCard(_ rect: CGRect, opacity: CGFloat) {
        guard let clip = cardClip else { return }
        if clip.frame != rect { clip.frame = rect }
        let origin = Self.glassOrigin(in: rect)
        if glass.frame.origin != origin { glass.setFrameOrigin(origin) }
        if clip.alphaValue != opacity { clip.alphaValue = opacity }
    }

    /// One group from `old` to `new` on every key path the ghost animates, so this call takes over
    /// every earlier one and its landing is the ghost's (``RenderSpring``'s call order). The root
    /// springs from `shift` away (a jump) at `velocity`, points per second. The glass springs against
    /// the card's clip by the same amount on the same curve, so it stays still on the root.
    func spring(from old: TabDragGhostRest, to new: TabDragGhostRest, shift: CGPoint, velocity: CGVector, token: MotionSpring) {
        guard let rootLayer = root.layer, let clipLayer = cardClip?.layer, let glassLayer = glass.layer else { return lay(new, landing: true) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeCard(new.glass, opacity: new.glassOpacity)
        CATransaction.commit()
        // AppKit placed the root at rest; both hosts are unflipped, so a screen offset is a position offset.
        let position = rootLayer.position
        var moves = [
            RenderSpring.Move(rootLayer, .positionX, from: position.x + shift.x, to: position.x, velocity: velocity.dx),
            RenderSpring.Move(rootLayer, .positionY, from: position.y + shift.y, to: position.y, velocity: velocity.dy),
        ]
        moves += Self.frameMoves(clipLayer, from: old.glass, to: new.glass)
        moves.append(RenderSpring.Move(glassLayer, .position, from: Self.position(of: glassLayer, at: Self.glassOrigin(in: old.glass)),
                                       to: Self.position(of: glassLayer, at: Self.glassOrigin(in: new.glass))))
        moves += Self.frameMoves(thumbLayer, from: old.thumb, to: new.thumb)
        moves += Self.frameMoves(tabLayer, from: old.tab, to: new.tab)
        moves += [
            RenderSpring.Move(clipLayer, .opacity, from: old.glassOpacity, to: new.glassOpacity),
            RenderSpring.Move(thumbLayer, .opacity, from: old.thumbOpacity, to: new.thumbOpacity),
            RenderSpring.Move(tabLayer, .opacity, from: old.tabOpacity, to: new.tabOpacity),
            RenderSpring.Move(tabLayer, .shadowOpacity, from: old.tabShadow, to: new.tabShadow),
        ]
        isAtRest = false
        Motion.tabs.renderSpring(token).animateGroup(moves, in: root) { [weak self] finished in
            guard finished, let self else { return }
            flight = TabDragGhostFlight()
            isAtRest = true
            onRest?()
        }
    }

    /// The glass's origin in a card clip at `card`: the root's origin.
    static func glassOrigin(in card: CGRect) -> CGPoint { CGPoint(x: -card.minX, y: -card.minY) }

    /// `layer`'s position when its frame's origin is `origin` (its size unchanged).
    static func position(of layer: CALayer, at origin: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + layer.anchorPoint.x * layer.bounds.width, y: origin.y + layer.anchorPoint.y * layer.bounds.height)
    }

    /// A layer's frame change as its position and size springs (its transform is the identity).
    static func frameMoves(_ layer: CALayer, from: CGRect, to: CGRect) -> [RenderSpring.Move] {
        let anchor = layer.anchorPoint
        func position(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.minX + anchor.x * rect.width, y: rect.minY + anchor.y * rect.height) }
        return [
            RenderSpring.Move(layer, .position, from: position(from), to: position(to)),
            RenderSpring.Move(layer, .boundsSize, from: from.size, to: to.size),
        ]
    }

    /// Whether the ghost shows in the source window's overlay (tests, `debug.tab_drag`).
    var isInSourceWindow: Bool { if case .window = host { true } else { false } }

    /// Where the ghost shows (`debug.tab_drag`): "panel", "window" (the source window's overlay) or "hidden".
    var hostName: String {
        guard rendersOnServer else { return panel.isVisible ? "panel" : "hidden" }
        switch host {
        case .hidden: return "hidden"
        case .panel: return "panel"
        case .window: return "window"
        }
    }
}

/// Layer-backed view of the ghost that never takes the mouse.
private final class TabDragGhostRootView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
