import AppKit
import CmuxNextDesign
import QuartzCore

/// The card under a floating pane: a ground with a rim and a shadow, a bar above the pane that a pointer moves the
/// pane by, and a band on each of its 4 edges and 4 corners that a pointer resizes it by. The pane's host is a
/// sibling above the card, so the card takes only the presses on its bar and its rim, never one on the content.
///
/// The band reaches outside the card's edge (``FloatingPaneReach``), so the view is the card and that part of the
/// band: ``cardBounds`` is the card in it. A press in the band outside the card is the card's, also over a tiled
/// pane; the card draws nothing there.
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
    /// The clip of the pane's host while this card is a solid ground under it.
    private weak var solidUnder: PaneClipView?

    private let shadeView = FloatingPaneLayerView(), surfaceView = FloatingPaneLayerView()
    private var material: FloatingPaneMaterialView?
    private let shade = CALayer(), shadeMask = CAShapeLayer()
    private let ground = CAShapeLayer(), tint = CAShapeLayer(), rim = CAShapeLayer(), grip = CALayer()
    /// The zone of the drag in progress: its cursor stays until the release.
    private var dragZone: Zone?
    /// How far the resize reaches, and the band outside the card on each side of this view.
    private(set) var reach = FloatingPaneReach()
    private(set) var outsets = FloatingPaneReach.Outsets()
    /// The views in front that hide a part of this view (the superview's coordinates): no cursor shows under them.
    private var covers: [CGRect] = []
    /// The card in this view and in its superview: the view less the band outside the card.
    var cardBounds: CGRect { outsets.card(in: bounds) }
    var cardFrame: CGRect { outsets.card(in: frame) }

    init(pane: PaneID) {
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        // `render()` puts the two on the card: they do not follow the view's size.
        for view in [shadeView, surfaceView] { addSubview(view) }
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

    /// Puts the card at `card` (the superview's coordinates) with the band of `reach` around it, held inside `area`.
    /// `covers` are the views in front of it. Returns true when the view moved.
    @discardableResult
    func place(_ card: CGRect, reach: FloatingPaneReach, in area: CGRect, under covers: [CGRect] = []) -> Bool {
        let outsets = reach.outsets(of: card, in: area), target = outsets.grown(card)
        let moved = target != frame, sized = target.size != frame.size
        let zonesChanged = reach != self.reach || outsets != self.outsets || covers != self.covers
        guard moved || zonesChanged else { return false }
        let bandChanged = outsets != self.outsets
        (self.reach, self.outsets, self.covers) = (reach, outsets, covers)
        if moved { frame = target }
        // A new size paints the card in `setFrameSize`; a new band with the same size moves the card in the view.
        if bandChanged, !sized { render() }
        window?.invalidateCursorRects(for: self)
        return moved
    }

    /// Shows the card with `look` and `corners`. A card that has both already does no work.
    func show(look: FloatingPaneLook, corners: FloatingPaneCorners) {
        guard look != self.look || corners != self.corners else { return }
        (self.look, self.corners) = (look, corners)
        render()
    }

    /// With a see-through look the card paints the ground of the pane in `host`: the views inside that host paint
    /// none, and the card takes their ground now and at each change of it. Else (also with no host: the pane does
    /// not float any more) the host that the card painted for paints its own ground again. With a solid look the
    /// host knows that the card's opaque ground is under it, not the window's sheet: a terminal with a background of
    /// its own paints that background opaque, not at a see-through window's tint (the two would mix under its text).
    /// The card puts its mark on the host's clip in each pass: a host that a screen's view placed between two passes
    /// lost its marks there (`PaneHostView.viewDidMoveToSuperview`).
    func paintGround(of host: PaneHostView?, seeThrough: Bool) {
        let clip = seeThrough ? host?.clipView : nil
        if groundOwner !== clip {
            if let old = groundOwner, isUnderThisCard(old) {
                old.onContentGroundChange = nil
                old.ownsContentGround = false
            }
            groundOwner = clip
        }
        if let clip, !clip.ownsContentGround {
            clip.onContentGroundChange = { [weak self, weak host] in self?.contentGround = host?.content.paneGroundColor }
            clip.ownsContentGround = true
        }
        contentGround = clip == nil ? nil : host?.content.paneGroundColor
        let solid = seeThrough ? nil : host?.clipView
        if solidUnder !== solid {
            if let old = solidUnder, isUnderThisCard(old) { old.hasSolidGroundUnder = false }
            solidUnder = solid
        }
        solid?.hasSolidGroundUnder = true
    }

    /// Whether the host of `clip` is in this card's screen view now. A host that another screen's view took has no
    /// mark of this card (the host cleared its marks when it moved): a mark that its clip has now is another card's.
    private func isUnderThisCard(_ clip: PaneClipView) -> Bool { clip.superview?.superview === superview }

    /// Paints the shadow, the material, the ground, the tint, the rim and the grip for the card's size, corners and
    /// look, with no implicit animation: a resize follows the pointer in the same frame.
    private func render() {
        // The layers' views are on the card; `bounds` below is the card in their coordinates.
        let card = cardBounds, bounds = CGRect(origin: .zero, size: card.size)
        for view in [shadeView, surfaceView] where view.frame != card { view.frame = card }
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
            let view = FloatingPaneMaterialView(frame: card)
            addSubview(view, positioned: .below, relativeTo: surfaceView)
            material = view
            return view
        }()
        if view.frame != card { view.frame = card }
        view.show(system, corners: corners)
    }

    /// The zone at `point` (the view's coordinates), by ``FloatingPaneReach``: nil in the pane's own rectangle, where
    /// the pane's host takes the press.
    func part(at point: CGPoint) -> Zone? { reach.zone(at: point, card: cardBounds, outsets: outsets) }

    /// The zone of a press at `point` (the view's coordinates).
    func zone(at point: CGPoint) -> Zone { part(at: point) ?? .move }

    /// The rectangles that show a zone's cursor (the view's coordinates): each zone's, less the parts under a view
    /// in front. AppKit does not hide a cursor rectangle under a sibling view above it.
    var cursorRects: [(zone: Zone, rect: CGRect)] {
        // The superview has its origin at the top left, as this view has.
        let hidden = covers.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
        return reach.zoneRects(card: cardBounds, outsets: outsets).flatMap { entry in
            FloatingPaneReach.parts(of: entry.rect, outside: hidden).map { (zone: entry.zone, rect: $0) }
        }
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
        for entry in cursorRects where !entry.rect.isEmpty {
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
