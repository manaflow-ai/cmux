import AppKit
import CmuxNextDesign

/// One scene node drawn in AppKit (``AppSceneNativeView``). The reconciler keeps one view per node
/// id and calls ``configure(_:)`` with each new value of the node, so an `update` op reconfigures the
/// view in place rather than rebuilding the section. Subclasses draw their node type; this base
/// applies the props every node accepts (padding, help, opacity, disabled), a tap for a node with an
/// `onTap` handler, and its context `menu`. Layout is manual: a parent asks ``height(width:)`` and
/// ``naturalWidth`` and sets the frame.
class AppSceneNodeNSView: NSView {
    let nodeID: String
    private(set) var node: AppSceneNode
    /// Where input goes: the mount's model, which forwards to the app supervisor.
    weak var model: AppSceneModel?
    /// A container's laid-out children, in order (set by the reconciler).
    private(set) var childViews: [AppSceneNodeNSView] = []
    private var isPressed = false

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
        self.node = node
        toolTip = node.string("help").flatMap { $0.isEmpty ? nil : $0 }
        alphaValue = node.number("opacity").map { CGFloat(min(max($0, 0), 1)) } ?? 1
        needsLayout = true
        needsDisplay = true
    }

    /// Replaces the container's children, keeping views that stay (no flicker, no lost hover).
    func setChildren(_ views: [AppSceneNodeNSView]) {
        guard views.map(ObjectIdentifier.init) != childViews.map(ObjectIdentifier.init) else { return }
        let keep = Set(views.map(ObjectIdentifier.init))
        for old in childViews where !keep.contains(ObjectIdentifier(old)) && old.superview === childHost { old.removeFromSuperview() }
        for view in views where view.superview !== childHost { childHost.addSubview(view) }
        childViews = views
        needsLayout = true
    }

    /// The view children are added to (a panel puts them above its surface).
    var childHost: NSView { self }

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
        let p = padding
        return contentHeight(width: max(0, width - p.left - p.right)) + p.top + p.bottom
    }

    /// The node's own width when it does not fill its parent (text, an icon, a badge), padding
    /// included; nil when it fills (rows, stacks, panels).
    final var naturalWidth: CGFloat? {
        let p = padding
        return contentNaturalWidth.map { $0 + p.left + p.right }
    }

    /// A Spacer: takes the room a horizontal stack has left.
    var isSpacer: Bool { false }

    func contentHeight(width: CGFloat) -> CGFloat { 0 }
    var contentNaturalWidth: CGFloat? { nil }
    /// Lays the content out in `rect` (the bounds less the padding).
    func layoutContent(in rect: CGRect) {}

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override func layout() {
        super.layout()
        let p = padding
        layoutContent(in: CGRect(x: p.left, y: p.top, width: max(0, bounds.width - p.left - p.right),
                                 height: max(0, bounds.height - p.top - p.bottom)))
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
        guard let items = node.props["menu"]?.arrayValue, !items.isEmpty else { return super.menu(for: event) }
        // The view keeps the menu's target alive while it shows (a menu item holds its target weakly).
        let owner = AppSceneContextMenu(items: items) { [weak self] path in
            self?.send("menu", ["path": .array(path.map { .number(Double($0)) })])
        }
        contextMenuOwner = owner
        return owner.menu
    }

    /// The target of the last context menu this view showed.
    private var contextMenuOwner: AppSceneContextMenu?
}
