import AppKit
import CmuxNextDesign

/// One scene node drawn in AppKit (``AppSceneNativeView``). The reconciler keeps one view per node
/// id and calls ``configure(_:)`` with each new value of the node, so an `update` op reconfigures the
/// view in place rather than rebuilding the section. Subclasses draw their node type; this base
/// applies the props every node accepts (padding, help, opacity, disabled, and the decorations:
/// `frame`, `background`, `glass`, `borderColor`, `cornerRadius`, `hoverBackground`, `rotation`), a tap for a
/// node with an `onTap` handler, and its context `menu`. Layout is manual: a parent asks
/// ``height(width:)`` and ``naturalWidth`` and sets the frame. Colors are painted in ``paint()``,
/// inside the view's theme scope, on each draw.
class AppSceneNodeNSView: NSView {
    let nodeID: String
    private(set) var node: AppSceneNode
    /// Where input goes: the mount's model, which forwards to the app supervisor.
    weak var model: AppSceneModel?
    /// A container's laid-out children, in order (set by the reconciler).
    private(set) var childViews: [AppSceneNodeNSView] = []
    /// The container drew its children once: a child added after this moves in by its `transition`.
    private(set) var hasDrawnChildren = false
    /// The node left its parent and its `transition` moves it out.
    var isLeaving = false
    /// The app bundle's folder (an `Image` node's `src` is inside it), set by the reconciler.
    var bundleDirectory: URL?
    /// The node draws in a widget tile (``AppSceneNativeView/fillsBounds``). Only there do spacers
    /// take a tall stack's slack and `transition` / `contentTransition` run: every other app scene
    /// (a sidebar section, a hover card, a pane) draws as it did before widgets
    /// (AppSceneDefaultUnchangedTests).
    var drawsInWidgetTile: Bool {
        var view = superview
        while let current = view {
            if let native = current as? AppSceneNativeView { return native.fillsBounds }
            view = current.superview
        }
        return false
    }
    private var isPressed = false
    /// Tracks the pointer while the node has a `hoverBackground` (a local wash, no script round trip).
    var decorationHover: PointerHover?
    /// Whether the pointer is over a node with a `hoverBackground`.
    var isDecorationHovered = false
    /// The App's own glass under the node's content, while the node has a `glass` level.
    var decorationGlass: (level: GlassLevel, view: NSView)?
    /// Draws a gradient `background` under the node's content; made the first time a node asks for one.
    var decorationGradient: CAGradientLayer?

    // MARK: Motion state (AppSceneNodeNSView+Motion.swift)

    /// The node's value before the last ``configure(_:)`` (nil before the first).
    private(set) var previousNode: AppSceneNode?
    /// The node's `animation` while a prop change of it is being applied: set by ``configure(_:)``
    /// when the node has one and the value changed, cleared at the end of the layout that follows.
    /// Every animatable write in between animates from what is on screen.
    var changeMotion: SceneMotion?
    /// The node has a `transition` and has not entered yet.
    var enterPending = false
    /// The scale, rotation and offset the layer's model transform was built from.
    var appliedTransform: SceneTransformParts?
    /// The running loop: what it was built for and when it began (its phase survives a rebuild).
    var appliedLoop: (loop: SceneLoop, size: CGSize, begin: CFTimeInterval)?
    /// The `shimmer` loop's clip and its band.
    var shimmerClip: CALayer?
    /// A non-shape node's `gradient` background.
    var gradientLayer: CAGradientLayer?
    /// Rebuilds the loop when Reduce Motion or the motion settings change.
    var motionSubscription: MotionSubscription?
    /// The parent's child host while the node plays its exit transition, removed from the scene.
    weak var exitHost: NSView?
    var exitToken = 0
    /// Distinct keys for additive animations, which run side by side.
    var additiveSerial = 0
    /// The container the children sit in while the node is `clipped` (AppSceneNodeNSView+Clip.swift).
    var clipView: AppSceneClipView?

    init(id: String, node: AppSceneNode) {
        nodeID = id
        self.node = node
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }

    /// Applies a new value of the node; subclasses call super first, then draw their own props.
    func configure(_ node: AppSceneNode) {
        let first = previousNode == nil
        previousNode = first ? node : self.node
        changeMotion = !first && node != self.node && window != nil ? node.motion : nil
        if first { enterPending = node.transition != nil }
        self.node = node
        themedToolTip = node.string("help").flatMap { $0.isEmpty ? nil : $0 }
        setOpacity(node.number("opacity").map { CGFloat(min(max($0, 0), 1)) } ?? 1)
        configureDecorations()
        configureMotion()
        configureClip()
        // An animated change paints its colors now, while the change's motion is known.
        if changeMotion != nil { performWithTheme { paint() } }
        needsLayout = true
        needsDisplay = true
    }

    /// The decorations, then the subclass's own colors, in the view's theme scope.
    final override func updateLayer() {
        performWithTheme {
            paintDecorations()
            paint()
        }
    }

    /// Paints the node's own colors (text, tints, fills); runs inside the theme scope on each draw.
    func paint() {}

    /// The layer that carries the `glow` shadow: the node's own, or a shape's drawn outline.
    var glowLayer: CALayer? { layer }
    /// Whether `gradient` paints this node's background (a shape fills its outline with it instead).
    var drawsGradientBackground: Bool { true }
    /// Whether the node clips what it draws to its bounds even without a `cornerRadius` (particles).
    var clipsContent: Bool { false }
    /// The outline a `shimmer` band is clipped to, in the view's coordinates (nil: the rounded bounds).
    var shimmerOutline: CGPath? { nil }

    /// Replaces the container's children, keeping views that stay (no flicker, no lost hover).
    func setChildren(_ views: [AppSceneNodeNSView]) {
        guard views.map(ObjectIdentifier.init) != childViews.map(ObjectIdentifier.init) else { return }
        let keep = Set(views.map(ObjectIdentifier.init))
        // After the first frame a child's `transition` moves it in and out (AppSceneNodeNSView+Transition),
        // in a widget tile only; a tile's `pop`, which that leaves alone, plays the SDK motion contract's
        // (AppSceneNodeNSView+Motion).
        let tile = drawsInWidgetTile
        let transitions = hasDrawnChildren && window != nil && tile
        // The new children first: an exit that ends at once (a window with no screen, motion off) asks
        // them whether the node came back, and must find it gone.
        let previous = childViews
        childViews = views
        for old in previous where !keep.contains(ObjectIdentifier(old)) && old.superview === childHost {
            guard transitions, old.sceneTransition != nil else {
                // A tile's `pop` child plays the SDK exit first (AppSceneNodeNSView+Motion); one that
                // moves to another parent stops it.
                if !(tile && old.beginExit(from: childHost)) { old.removeFromSuperview() }
                continue
            }
            old.transitionOut { [weak self, weak old] in
                // Back in the tree before its exit ended: it stays.
                guard let self, let old, !self.childViews.contains(where: { $0 === old }) else { return }
                old.removeFromSuperview()
            }
        }
        for view in views where view.superview !== childHost || view.isLeaving {
            if view.superview !== childHost { childHost.addSubview(view) }
            if transitions, view.sceneTransition != nil {
                view.transitionIn()
            } else if view.isLeaving {
                // Back before its exit ended, with no entrance to run: at rest now, and the exit's
                // completion finds it no longer leaving.
                view.settleAtRest()
            }
        }
        hasDrawnChildren = true
        needsLayout = true
    }

    /// The view children are added to (a panel puts them above its surface).
    var childHost: NSView { clipView ?? self }
    /// Whether the children sit in this view (not in a content view of its own, as a panel's do).
    var hostsChildrenInSelf: Bool { true }

    // MARK: Layout

    /// `padding` (a number or `{top, leading, bottom, trailing}`) plus `paddingHorizontal` / `paddingVertical`.
    var padding: NSEdgeInsets {
        var insets = NSEdgeInsets()
        switch node.props["padding"] {
        case .number(let all)?: insets = NSEdgeInsets(top: all, left: all, bottom: all, right: all)
        case .object(let edges)?:
            insets = NSEdgeInsets(top: edges["top"]?.numberValue ?? 0, left: edges["leading"]?.numberValue ?? 0,
                                  bottom: edges["bottom"]?.numberValue ?? 0, right: edges["trailing"]?.numberValue ?? 0)
        default: break
        }
        if let h = node.number("paddingHorizontal") { (insets.left, insets.right) = (h, h) }
        if let v = node.number("paddingVertical") { (insets.top, insets.bottom) = (v, v) }
        return insets
    }

    /// The node's height when laid out `width` points wide, padding included.
    final func height(width: CGFloat) -> CGFloat {
        if let fixed = frameDimension("height"), fixed.isFinite { return fixed }
        // A frame's width (or its maxWidth) is the width the content lays out in, as in the parent's frame.
        var width = width
        if let fixed = frameDimension("width"), fixed.isFinite { width = min(width, fixed) }
        if let high = frameDimension("maxWidth"), high.isFinite { width = min(width, high) }
        let p = padding
        return clampedHeight(contentHeight(width: max(0, width - p.left - p.right)) + p.top + p.bottom)
    }

    /// The node's own width when it does not fill its parent (text, an icon, a badge), padding
    /// included; nil when it fills (rows, stacks, panels).
    final var naturalWidth: CGFloat? {
        if let fixed = frameDimension("width"), fixed.isFinite { return fixed }
        let p = padding
        return clampedNaturalWidth(contentNaturalWidth.map { $0 + p.left + p.right })
    }

    /// A Spacer: takes the room a horizontal stack has left.
    var isSpacer: Bool { false }

    func contentHeight(width: CGFloat) -> CGFloat { 0 }
    var contentNaturalWidth: CGFloat? { nil }
    /// The first text baseline's distance below the node's top, laid out `width` wide; nil without text
    /// (an HStack's `firstTextBaseline` then aligns the node's bottom, as SwiftUI does).
    func firstBaseline(width: CGFloat) -> CGFloat? { nil }
    /// The last text baseline's distance above the node's bottom; nil without text.
    func lastBaselineFromBottom(width: CGFloat) -> CGFloat? { nil }
    /// Lays the content out in `rect` (the bounds less the padding).
    func layoutContent(in rect: CGRect) {}

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        guard newSize != old else { return }
        needsLayout = true
        // An animated `frame` change grows the node's own layer from its old size.
        if previousNode?.props["frame"] != node.props["frame"], old.width > 0 || old.height > 0, let layer {
            animateAdditive(layer, "bounds", from: NSValue(rect: CGRect(x: 0, y: 0, width: old.width - newSize.width, height: old.height - newSize.height)),
                            zero: NSValue(rect: .zero))
        }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        // AppKit owns the backing layer's geometry: a move keeps `scale`, `rotation` and `offset`.
        reassertTransform()
    }

    /// A node on its way out (its exit transition) takes no clicks: the scene removed it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard exitHost == nil else { return nil }

        // AppKit's default hit testing follows NSView frames. Scene motion is a transform on the
        // backing layer, so a moved or scaled child can be drawn outside that frame. Walk children
        // ourselves and convert through their layers; CALayer conversion applies the node's current
        // model/presentation transform before the child's local bounds are tested.
        let host = childHost
        let hostPoint = host === self ? point : host.convert(point, from: self)
        for child in host.subviews.reversed().compactMap({ $0 as? AppSceneNodeNSView }) {
            let childPoint: NSPoint
            if let childLayer = child.layer, let hostLayer = host.layer {
                childPoint = childLayer.convert(hostPoint, from: hostLayer)
            } else {
                childPoint = child.convert(hostPoint, from: host)
            }
            if let hit = child.hitTest(childPoint) { return hit }
        }

        // Keep the existing behavior for this node (including context menus), but only after
        // transformed descendants had a chance to receive the event.
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        layoutDecorations()
        if let clipView { withoutActions { clipView.frame = bounds } }
        let p = padding
        layoutContent(in: CGRect(x: p.left, y: p.top, width: max(0, bounds.width - p.left - p.right),
                                 height: max(0, bounds.height - p.top - p.bottom)))
        layoutMotion()
        changeMotion = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        motionWindowChanged()
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        // Taken back into the scene (or moved elsewhere) mid-exit: it stays.
        if exitHost != nil, newSuperview !== exitHost { cancelExit() }
    }

    // MARK: Input

    /// Sends `event` for this node to the script.
    func send(_ event: String, _ payload: AppJSON = .object([:])) {
        model?.send(nodeID, event, payload)
    }

    /// Whether a click on this view is a tap (a Button always is; any node with an `onTap` handler).
    var isTappable: Bool { node.flag("onTap") && !node.flag("disabled") }

    /// The press state changed (a row paints its fill).
    func pressChanged(_ pressed: Bool) {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isTappable }

    override func mouseDown(with event: NSEvent) {
        guard isTappable else { return super.mouseDown(with: event) }
        isPressed = true
        pressChanged(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTappable else { return super.mouseDragged(with: event) }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != isPressed {
            isPressed = inside
            pressChanged(inside)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isTappable else { return super.mouseUp(with: event) }
        let fire = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        pressChanged(false)
        if fire { send("tap") }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isTappable else { return false }
        send("tap")
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let items = node.props["menu"]?.arrayValue, !items.isEmpty else { return NSMenu.withoutSystemItems(super.menu(for: event)) }
        // The view keeps the menu's target alive while it shows (a menu item holds its target weakly).
        let owner = AppSceneContextMenu(items: items) { [weak self] path in
            self?.send("menu", ["path": .array(path.map { .number(Double($0)) })])
        }
        contextMenuOwner = owner
        return NSMenu.withoutSystemItems(owner.menu)
    }

    /// The target of the last context menu this view showed.
    private var contextMenuOwner: AppSceneContextMenu?
}
