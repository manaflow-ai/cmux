import AppKit
import CmuxNextDesign
import QuartzCore

/// The card under a floating pane: a ground with a rim and a shadow, a bar above the pane that a pointer moves the
/// pane by, and a band on each of its 4 edges and 4 corners that a pointer resizes it by. The pane's host is a
/// sibling above the card, so the card takes only the presses on its bar and its rim, never one on the content.
///
/// Its corners follow the window's corners (``FloatingPaneCorners``) and its look comes from the Floating Pane
/// knobs (`FloatingPaneLook`). With a see-through background the card paints the one ground of the pane, at the
/// look's opacity, and the content above it paints none (`PaneGroundOwning`).
final class FloatingPaneCardView: NSView {
    /// The part of the card under the pointer: what a drag from there changes.
    enum Zone: CaseIterable {
        case move, top, left, right, bottom, topLeft, topRight, bottomLeft, bottomRight

        /// The edges of the card that a drag from this zone moves. The opposite edges stay where they are.
        var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
        var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
        var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
        var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    }

    enum Phase { case began(Zone), moved, ended }

    let pane: PaneID
    /// A press on the card, its drag and its release.
    var onDrag: ((Phase, NSEvent) -> Void)?
    private(set) var look = FloatingPaneLook()
    private(set) var corners = FloatingPaneCorners(uniform: 0)
    /// The ground of the pane's content (a terminal's own background): the card paints it while the look is
    /// see-through. Nil: the page background.
    var contentGround: CGColor? {
        didSet { if contentGround != oldValue { render() } }
    }
    /// The clip of the pane's host while this card paints its ground.
    weak var groundOwner: PaneClipView?

    private let shadeView = FloatingPaneLayerView(), surfaceView = FloatingPaneLayerView()
    private var material: FloatingPaneMaterialView?
    private let shade = CALayer(), shadeMask = CAShapeLayer()
    private let ground = CAShapeLayer(), tint = CAShapeLayer(), rim = CAShapeLayer(), grip = CALayer()
    /// The zone of the drag in progress: its cursor stays until the release.
    private var dragZone: Zone?
    /// The length along the rim, from each corner, that resizes both ways.
    static let cornerLength: CGFloat = 14

    init(pane: PaneID) {
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        for view in [shadeView, surfaceView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        shadeMask.fillRule = .evenOdd
        // Alpha-only coverage of the mask: this colour is never displayed.
        shadeMask.fillColor = NSColor.black.cgColor
        shade.mask = shadeMask
        shade.shadowColor = NSColor.black.cgColor
        shadeView.layer?.addSublayer(shade)
        rim.fillColor = nil
        for layer in [ground, tint, rim, grip] { surfaceView.layer?.addSublayer(layer) }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The card takes each press on it; its layers' views take none.
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    /// A theme change paints the card again.
    override func updateLayer() { render() }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        render()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let changed = newOrigin != frame.origin
        super.setFrameOrigin(newOrigin)
        if changed { window?.invalidateCursorRects(for: self) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // A change of the order of the screen's views is no move out of the window: a drag keeps its cursor.
        if newWindow !== window { endDragCursor() }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Shows the card with `look` and `corners`. A card that has both already does no work.
    func show(look: FloatingPaneLook, corners: FloatingPaneCorners) {
        guard look != self.look || corners != self.corners else { return }
        (self.look, self.corners) = (look, corners)
        render()
    }

    /// With a see-through look the card paints the ground of the pane in `host`: the views inside that host paint
    /// none, and the card takes their ground now and at each change of it. Else (also with no host: the pane does
    /// not float any more) the host that the card painted for paints its own ground again.
    func paintGround(of host: PaneHostView?, seeThrough: Bool) {
        let clip = seeThrough ? host?.clipView : nil
        if groundOwner !== clip {
            groundOwner?.onContentGroundChange = nil
            groundOwner?.ownsContentGround = false
            groundOwner = clip
            clip?.onContentGroundChange = { [weak self, weak host] in self?.contentGround = host?.content.paneGroundColor }
            clip?.ownsContentGround = true
        }
        contentGround = clip == nil ? nil : host?.content.paneGroundColor
    }

    /// Paints the shadow, the material, the ground, the tint, the rim and the grip for the card's size, corners and
    /// look, with no implicit animation: a resize follows the pointer in the same frame.
    private func render() {
        let outline = corners.path(in: bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // The shadow lies outside the card only: under a see-through ground it would darken the panes below.
        let reach = look.shadowBlur * 2 + abs(look.shadowOffset) + 2
        shade.frame = bounds
        shade.shadowPath = outline
        shade.shadowOpacity = Float(look.shadowOpacity)
        shade.shadowRadius = look.shadowBlur
        shade.shadowOffset = CGSize(width: 0, height: look.shadowOffset)
        let around = CGMutablePath()
        shadeMask.frame = bounds.insetBy(dx: -reach, dy: -reach)
        around.addRect(shadeMask.bounds)
        around.addPath(outline, transform: CGAffineTransform(translationX: reach, y: reach))
        shadeMask.path = around
        for shape in [ground, tint, rim] { shape.frame = bounds }
        ground.path = outline
        tint.path = outline
        rim.path = corners.path(in: bounds, inset: look.borderWidth / 2)
        rim.lineWidth = look.borderWidth
        performWithTheme {
            let base = (look.isSeeThrough ? contentGround : nil) ?? Palette.pageBackground.cgColor
            ground.fillColor = base.copy(alpha: base.alpha * look.backgroundOpacity)
            tint.fillColor = look.tintStrength > 0 ? Palette.tunable(look.tint).cgColor.copy(alpha: look.tintStrength) : nil
            let line = Palette.paneBorder.cgColor
            rim.strokeColor = look.borderWidth > 0 ? line.copy(alpha: line.alpha * look.borderOpacity) : nil
            grip.backgroundColor = line
        }
        let height: CGFloat = 4, width = min(36, max(0, bounds.width - 24))
        grip.frame = CGRect(x: (bounds.width - width) / 2, y: LayoutFloatingPane.rimWidth + (LayoutFloatingPane.barHeight - LayoutFloatingPane.rimWidth - height) / 2,
                            width: width, height: height)
        grip.cornerRadius = height / 2
        guard look.isSeeThrough, let system = look.material.system else {
            material?.removeFromSuperview()
            material = nil
            return
        }
        let view = material ?? {
            let view = FloatingPaneMaterialView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            addSubview(view, positioned: .below, relativeTo: surfaceView)
            material = view
            return view
        }()
        if view.frame != bounds { view.frame = bounds }
        view.show(system, corners: corners)
    }

    /// The zone at `point` (the card's coordinates): a corner within ``cornerLength`` of it along the rim, an edge
    /// on the rest of the rim, the bar below the top rim, else the move zone.
    func zone(at point: CGPoint) -> Zone {
        let rim = LayoutFloatingPane.rimWidth, corner = Self.cornerLength
        let left = point.x < bounds.minX + rim, right = point.x >= bounds.maxX - rim
        let top = point.y < bounds.minY + rim, bottom = point.y >= bounds.maxY - rim
        let nearLeft = point.x < bounds.minX + corner, nearRight = point.x >= bounds.maxX - corner
        let nearTop = point.y < bounds.minY + corner, nearBottom = point.y >= bounds.maxY - corner
        if top && nearLeft || left && nearTop { return .topLeft }
        if top && nearRight || right && nearTop { return .topRight }
        if bottom && nearLeft || left && nearBottom { return .bottomLeft }
        if bottom && nearRight || right && nearBottom { return .bottomRight }
        if top { return .top }
        if bottom { return .bottom }
        if left { return .left }
        return right ? .right : .move
    }

    /// The rectangles of each zone that the card shows (the bar and the rim; the pane's host covers the rest). No
    /// two overlap, so each point has one cursor.
    static func zoneRects(in bounds: CGRect) -> [(zone: Zone, rect: CGRect)] {
        let rim = LayoutFloatingPane.rimWidth, bar = LayoutFloatingPane.barHeight, corner = cornerLength
        let (minX, minY, maxX, maxY) = (bounds.minX, bounds.minY, bounds.maxX, bounds.maxY)
        let across = max(0, bounds.width - corner * 2), down = max(0, bounds.height - corner * 2), stem = corner - rim
        return [
            (.topLeft, CGRect(x: minX, y: minY, width: corner, height: rim)),
            (.topLeft, CGRect(x: minX, y: minY + rim, width: rim, height: stem)),
            (.topRight, CGRect(x: maxX - corner, y: minY, width: corner, height: rim)),
            (.topRight, CGRect(x: maxX - rim, y: minY + rim, width: rim, height: stem)),
            (.bottomLeft, CGRect(x: minX, y: maxY - rim, width: corner, height: rim)),
            (.bottomLeft, CGRect(x: minX, y: maxY - corner, width: rim, height: stem)),
            (.bottomRight, CGRect(x: maxX - corner, y: maxY - rim, width: corner, height: rim)),
            (.bottomRight, CGRect(x: maxX - rim, y: maxY - corner, width: rim, height: stem)),
            (.top, CGRect(x: minX + corner, y: minY, width: across, height: rim)),
            (.bottom, CGRect(x: minX + corner, y: maxY - rim, width: across, height: rim)),
            (.left, CGRect(x: minX, y: minY + corner, width: rim, height: down)),
            (.right, CGRect(x: maxX - rim, y: minY + corner, width: rim, height: down)),
            (.move, CGRect(x: minX + rim, y: minY + rim, width: max(0, bounds.width - rim * 2), height: max(0, bar - rim))),
        ]
    }

    /// The cursor of `zone`: the system's frame resize cursor of that edge or corner (macOS 15 and later; before
    /// that the 2 edge cursors, and a crosshair at a corner). The bar shows an open hand, and a closed one in a drag.
    static func cursor(for zone: Zone, dragging: Bool = false) -> NSCursor {
        if zone == .move { return dragging ? .closedHand : .openHand }
        guard #available(macOS 15, *) else {
            switch zone {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            default: return .crosshair
            }
        }
        let position: NSCursor.FrameResizePosition = switch zone {
        case .top, .move: .top
        case .left: .left
        case .right: .right
        case .bottom: .bottom
        case .topLeft: .topLeft
        case .topRight: .topRight
        case .bottomLeft: .bottomLeft
        case .bottomRight: .bottomRight
        }
        return .frameResize(position: position, directions: .all)
    }

    /// The cursor shows on a hover of the band, before a press.
    override func resetCursorRects() {
        for entry in Self.zoneRects(in: bounds) where !entry.rect.isEmpty {
            addCursorRect(entry.rect, cursor: Self.cursor(for: entry.zone))
        }
    }

    /// In a drag the window's cursor rectangles are off and each event sets the zone's cursor again, so the
    /// cursor does not change to the content's when the pointer goes over the content.
    override func cursorUpdate(with event: NSEvent) {
        guard let dragZone else { return super.cursorUpdate(with: event) }
        Self.cursor(for: dragZone, dragging: true).set()
    }

    override func mouseDown(with event: NSEvent) {
        let zone = zone(at: convert(event.locationInWindow, from: nil))
        if dragZone == nil { window?.disableCursorRects() }
        dragZone = zone
        Self.cursor(for: zone, dragging: true).set()
        onDrag?(.began(zone), event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let dragZone { Self.cursor(for: dragZone, dragging: true).set() }
        onDrag?(.moved, event)
    }

    override func mouseUp(with event: NSEvent) {
        endDragCursor()
        onDrag?(.ended, event)
    }

    /// The drag's cursor ends: the window's cursor rectangles are on again.
    private func endDragCursor() {
        guard dragZone != nil else { return }
        dragZone = nil
        window?.enableCursorRects()
        window?.invalidateCursorRects(for: self)
    }
}

/// A view of a card that only holds layers: it takes no clicks.
private final class FloatingPaneLayerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
