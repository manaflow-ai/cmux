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
/// outside. No frame client steps it: Core Animation runs its springs (``present(_:token:inSourceWindow:landing:)``).
final class TabDragGhostPanel {
    let panel: NSPanel
    let root: NSView
    private let glass: GlassPanelView
    /// Render server only: the glass fills the root and this clip masks it to the card
    /// (`glassMask`), so the card unfolds as one mask spring, never a glass relayout per frame.
    private var glassClip: TabDragGhostRootView?
    let glassMask = CALayer()
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
    /// `motion.renderServer`: ``present(_:token:inSourceWindow:landing:)``, not ``render(_:)`` per frame.
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
        // On the render server the mask's corners are the card's.
        glass = Glass.makePanel(style: .regular, cornerRadius: rendersOnServer ? 0 : Metrics.panelCornerRadius)
        glass.translatesAutoresizingMaskIntoConstraints = true
        // The ghost is the whole content of a clear panel (or of the window's
        // clear overlay panel): before Liquid Glass the card blurs what is under it.
        glass.samplesBehindWindow = true
        if rendersOnServer {
            let clip = TabDragGhostRootView(frame: root.bounds)
            clip.wantsLayer = true
            glass.frame = clip.bounds
            glass.alphaValue = 1
            clip.addSubview(glass)
            root.addSubview(clip)
            glassMask.backgroundColor = NSColor.black.cgColor
            glassMask.cornerRadius = Metrics.panelCornerRadius
            glassMask.cornerCurve = .continuous
            glassMask.opacity = onGlass ? 1 : 0
            clip.layer?.mask = glassMask
            glassClip = clip
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
        onRest = nil
        leaveHost()
        panel.orderOut(nil)
    }

    /// A frame client of the ghost's own FrameScheduler (its screen, 120 Hz
    /// on ProMotion).
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

/// The ghost on the render server (chrome-parity p03-rendering-035): additive springs keep the presented
/// value and velocity continuous on a retarget (cc/animation/scroll_offset_animation_curve.cc `UpdateTarget`).
extension TabDragGhostPanel {
    /// The overlay host keeps an overlay this far inside the window (`WindowOverlayHost.origin`):
    /// the carrier sits there, and the root inside it anywhere, since the carrier does not clip.
    static let overlayInset: CGFloat = 8
    /// Room around what draws (the tab's shadow) that must fit in the source window.
    static let fitMargin: CGFloat = 8

    /// The rest of `motion`.
    func rest(_ motion: TabDragGhostMotion) -> TabDragGhostRest {
        let settled = motion.rest
        return TabDragGhostRest(layout: layout(settled), opacity: settled.presentedOpacity, rootSize: panelSize, pad: pad, inset: inset,
                                onGlass: onGlass, shadowAlpha: PopupStyle.elevation2.alpha)
    }

    /// Shows `motion` at rest, laid out once. A pointer move only moves the root in its host; a jump
    /// (``TabDragGhostMotion/jumpCount``), a morph or the landing is one spring group of `token` from
    /// what showed. `inSourceWindow`: the source window is frontmost under the pointer and holds the
    /// ghost while it fits. `landing`: the ghost keeps its host and ``onRest`` runs when it settles.
    func present(_ motion: TabDragGhostMotion, token: MotionSpring, inSourceWindow: Bool, landing: Bool = false) {
        let next = rest(motion)
        let previous = shown
        let jumped = previous != nil && motion.jumpCount != shownJumps
        shownJumps = motion.jumpCount
        shown = next
        let from = jumped ? previous?.origin : nil
        if pinsHost || landing, !host.isHidden {
            move(to: next.origin, from: from)
        } else {
            let window = inSourceWindow ? sourceWindow.flatMap { fits(next, in: $0) ? $0 : nil } : nil
            place(next.origin, in: window, from: from)
        }
        pinsHost = pinsHost || landing
        if let clip = glassClip, clip.layer?.mask !== glassMask { clip.layer?.mask = glassMask }
        guard let previous else { return lay(next, landing: landing) }
        guard landing || jumped || !previous.sameInside(next) else { return }
        spring(from: previous, to: next, shift: from.map { CGPoint(x: $0.x - next.origin.x, y: $0.y - next.origin.y) } ?? .zero,
               velocity: jumped ? motion.jumpVelocity : .zero, token: token)
    }

    /// Whether what draws at `rest` fits in `window`.
    func fits(_ rest: TabDragGhostRest, in window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized
            && window.frame.contains(rest.shownOnScreen.insetBy(dx: -Self.fitMargin, dy: -Self.fitMargin))
    }

    // MARK: Hosts

    /// Puts the root at the screen `origin` in the source window's overlay (`window`) or, with no
    /// window, in the panel. `from` is the root's previous origin when it jumps.
    func place(_ origin: CGPoint, in window: NSWindow?, from: CGPoint?) {
        if let window {
            if case .window = host { return move(to: origin, from: from) }
            leaveHost()
            let bounds = NSRect(origin: .zero, size: window.frame.size).insetBy(dx: Self.overlayInset, dy: Self.overlayInset)
            carrier.frame = bounds
            root.setFrameOrigin(.zero)
            carrier.addSubview(root)
            host = .window(WindowOverlayHost.host(for: window).present(carrier, options: OverlayOptions(kind: .dragGhost, anchor: bounds)))
            return move(to: origin, from: nil)
        }
        if case .panel = host { return move(to: origin, from: from) }
        leaveHost()
        panelContainer?.addSubview(root)
        root.setFrameOrigin(.zero)
        panel.setFrame(CGRect(origin: origin, size: panelSize), display: false)
        panel.orderFrontRegardless()
        host = .panel
    }

    /// Moves the root to the screen `origin` in its host. In the panel a jump (`from`) sizes the
    /// panel once to hold both places, so the flight between them is not clipped; a follow moves it.
    func move(to origin: CGPoint, from: CGPoint?) {
        switch host {
        case .hidden: return
        case .window:
            guard let overlay = carrier.window else { return }
            let local = carrier.convert(overlay.convertPoint(fromScreen: origin), from: nil)
            if root.frame.origin != local { root.setFrameOrigin(local) }
        case .panel:
            guard let from else {
                let panelOrigin = CGPoint(x: origin.x - root.frame.minX, y: origin.y - root.frame.minY)
                if panel.frame.origin != panelOrigin { panel.setFrameOrigin(panelOrigin) }
                return
            }
            let room = CGRect(origin: origin, size: panelSize).union(CGRect(origin: from, size: panelSize))
            panel.setFrame(room, display: false)
            root.setFrameOrigin(CGPoint(x: origin.x - room.minX, y: origin.y - room.minY))
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
        glassMask.frame = rest.glass
        glassMask.opacity = Float(rest.glassOpacity)
        thumbLayer.frame = rest.thumb
        thumbLayer.opacity = Float(rest.thumbOpacity)
        tabLayer.frame = rest.tab
        tabLayer.opacity = Float(rest.tabOpacity)
        tabLayer.shadowOpacity = Float(rest.tabShadow)
        CATransaction.commit()
        if landing { onRest?() }
    }

    /// One group from `old` to `new` on every key path the ghost animates, so this call takes over
    /// every earlier one and its landing is the ghost's (``RenderSpring``'s call order). The root
    /// springs from `shift` away (a jump) at `velocity`, points per second.
    func spring(from old: TabDragGhostRest, to new: TabDragGhostRest, shift: CGPoint, velocity: CGVector, token: MotionSpring) {
        guard let rootLayer = root.layer else { return lay(new, landing: true) }
        // AppKit placed the root at rest; both hosts are unflipped, so a screen offset is a position offset.
        let position = rootLayer.position
        var moves = [
            RenderSpring.Move(rootLayer, "position.x", from: position.x + shift.x, to: position.x, velocity: velocity.dx),
            RenderSpring.Move(rootLayer, "position.y", from: position.y + shift.y, to: position.y, velocity: velocity.dy),
        ]
        moves += Self.frameMoves(glassMask, from: old.glass, to: new.glass)
        moves += Self.frameMoves(thumbLayer, from: old.thumb, to: new.thumb)
        moves += Self.frameMoves(tabLayer, from: old.tab, to: new.tab)
        moves += [
            RenderSpring.Move(glassMask, "opacity", from: old.glassOpacity, to: new.glassOpacity),
            RenderSpring.Move(thumbLayer, "opacity", from: old.thumbOpacity, to: new.thumbOpacity),
            RenderSpring.Move(tabLayer, "opacity", from: old.tabOpacity, to: new.tabOpacity),
            RenderSpring.Move(tabLayer, "shadowOpacity", from: old.tabShadow, to: new.tabShadow),
        ]
        Motion.tabs.renderSpring(token).animateGroup(moves, in: root) { [weak self] finished in
            if finished { self?.onRest?() }
        }
    }

    /// A layer's frame change as its position and size springs (its transform is the identity).
    static func frameMoves(_ layer: CALayer, from: CGRect, to: CGRect) -> [RenderSpring.Move] {
        let anchor = layer.anchorPoint
        func position(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.minX + anchor.x * rect.width, y: rect.minY + anchor.y * rect.height) }
        return [
            RenderSpring.Move(layer, "position", from: position(from), to: position(to)),
            RenderSpring.Move(layer, "bounds.size", from: from.size, to: to.size),
        ]
    }

    /// Whether the ghost shows in the source window's overlay (tests).
    var isInSourceWindow: Bool { if case .window = host { true } else { false } }
}

/// Layer-backed view of the ghost that never takes the mouse.
private final class TabDragGhostRootView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
