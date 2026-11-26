public import CoreGraphics

/// Where a drop lands relative to its region.
public nonisolated enum DropOverlayZone: String, Sendable, Hashable, CaseIterable {
    case center, left, right, top, bottom
    /// Between columns (a new strip column).
    case column

    init(_ target: DropTarget) {
        switch target {
        case .newColumn: self = .column
        case let .newDock(_, edge):
            switch edge {
            case .left: self = .left
            case .right: self = .right
            case .top: self = .top
            case .bottom: self = .bottom
            }
        case let .pane(_, zone):
            switch zone {
            case .center: self = .center
            case .left: self = .left
            case .right: self = .right
            case .top: self = .top
            case .bottom: self = .bottom
            }
        }
    }

    /// Whether the drop splits the region in two.
    public var splits: Bool { self == .left || self == .right || self == .top || self == .bottom }
}

/// One frame of the overlay, in the overlay plane's (flipped) coordinates.
public nonisolated struct DropOverlayFrame: Equatable, Sendable {
    /// Where the tab lands (the highlight rect, animated).
    public var target: CGRect
    /// Where the target is heading (label rules use it, so a label does not
    /// flicker while the overlay grows or moves).
    public var finalTarget: CGRect
    /// The whole pane (or column gap) the target belongs to, animated.
    public var region: CGRect
    public var zone: DropOverlayZone
    /// The overlay plane's bounds.
    public var bounds: CGRect
    public var cornerRadius: CGFloat
    public var label: String
    public var showsLabel: Bool
    /// The target cannot take the drop; `label` is the reason (tab-dnd).
    public var refused: Bool
    /// The overlay may move to `finalTarget` with an animation (self-driven
    /// styles animate on the compositor; the others get every frame).
    public var animated: Bool
    /// The target is a pane, gap or dock region that classic fills; false
    /// for a tab strip's insert slot (`showTabDragOutline`), which stays a border.
    public var fills: Bool
    /// The final frames of the panes the drop resizes or moves, outlined
    /// beside the filled new pane (the final-layout preview, DESIGN.md (c)1).
    public var companions: [CGRect]

    public init(target: CGRect, finalTarget: CGRect? = nil, region: CGRect, zone: DropOverlayZone, bounds: CGRect,
                cornerRadius: CGFloat, label: String, showsLabel: Bool, refused: Bool = false, animated: Bool = false,
                fills: Bool = true, companions: [CGRect] = []) {
        self.refused = refused
        self.fills = fills
        self.companions = companions
        self.animated = animated
        self.target = target
        self.finalTarget = finalTarget ?? target
        self.region = region
        self.zone = zone
        self.bounds = bounds
        self.cornerRadius = cornerRadius
        self.label = label
        self.showsLabel = showsLabel
    }
}

/// Geometry of the overlay styles (flipped coordinates: y grows down). The
/// rects are Rust's (cmux-layout-reducer `drop_overlay_geometry`,
/// `drop_overlay_*`); a rect the reducer does not answer is empty, so nothing
/// draws. The paths stay here: they are CoreGraphics drawing.
public nonisolated enum DropOverlayGeometry {
    /// The two panes a split creates inside `region`: the incoming one on
    /// the zone's side and the existing one, each giving up half of `gap`.
    /// A center or column drop creates no second pane.
    public static func splitPreview(region: CGRect, zone: DropOverlayZone, gap: CGFloat) -> (incoming: CGRect, existing: CGRect?) {
        let request = Wire.SplitPreviewRequest(region: Wire.Rect(region), zone: zone.rawValue, gap: Double(gap))
        guard let reply = LayoutReducerJSON().call("drop_overlay_split_preview", request, as: Wire.SplitPreviewReply.self)
        else { return (region, nil) }
        return (reply.incoming.cgRect, reply.existing?.cgRect)
    }

    /// The insertion caret: on the line where the new divider appears for
    /// a split, along the tab strip (top edge) for a center drop, and down
    /// the middle of a column gap. `length` is a share of that edge.
    public static func insertionLine(region: CGRect, zone: DropOverlayZone, width: CGFloat, length: CGFloat) -> CGRect {
        Wire.rect("drop_overlay_insertion_line", Wire.InsertionLineRequest(region: Wire.Rect(region), zone: zone.rawValue,
                                                                            width: Double(width), length: Double(length)))
    }

    /// Edges a glow grows from: the side the new pane takes, every edge
    /// for a center drop or a column gap. None when the reducer does not answer.
    public static func glowEdges(_ zone: DropOverlayZone) -> [CGRectEdge] {
        let reply = LayoutReducerJSON().call("drop_overlay_glow_edges", Wire.ZoneRequest(zone: zone.rawValue),
                                             as: Wire.EdgesReply.self)
        return reply?.edges.compactMap(Wire.edge(named:)) ?? []
    }

    /// A band of `depth` along `edge` of `rect` (flipped: minY is the top).
    public static func band(_ rect: CGRect, edge: CGRectEdge, depth: CGFloat) -> CGRect {
        Wire.rect("drop_overlay_band", Wire.BandRequest(rect: Wire.Rect(rect), edge: Wire.edge(edge), depth: Double(depth)))
    }

    /// A card of `fraction` of the target's width (at most `maxWidth`) and
    /// `height`, centered in it and never larger than it.
    public static func insetCard(target: CGRect, fraction: CGFloat, maxWidth: CGFloat, height: CGFloat) -> CGRect {
        Wire.rect("drop_overlay_inset_card", Wire.InsetCardRequest(target: Wire.Rect(target), fraction: Double(fraction),
                                                                    maxWidth: Double(maxWidth), height: Double(height)))
    }

    /// The tab pill at the target's top leading corner, inset by `inset`,
    /// `width` wide (at most the target's width less the insets).
    public static func tabPill(target: CGRect, width: CGFloat, height: CGFloat, inset: CGFloat) -> CGRect {
        Wire.rect("drop_overlay_tab_pill", Wire.TabPillRequest(target: Wire.Rect(target), width: Double(width),
                                                                height: Double(height), inset: Double(inset)))
    }

    /// The card a morph starts from: centered on the pointer, `width` wide
    /// with a 3:2 aspect. A point at the pointer when the reducer does not answer.
    public static func morphStart(pointer: CGPoint, width: CGFloat) -> CGRect {
        let request = Wire.MorphStartRequest(pointer: Wire.Point(x: Double(pointer.x), y: Double(pointer.y)), width: Double(width))
        guard let reply = LayoutReducerJSON().call("drop_overlay_morph_start", request, as: Wire.RectReply.self) else {
            return CGRect(origin: pointer, size: .zero)
        }
        return reply.rect.cgRect
    }

    /// Everything in `bounds` except the rounded `hole` (even-odd fill).
    public static func spotlightPath(bounds: CGRect, hole: CGRect, cornerRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addPath(roundedRect(hole, cornerRadius))
        return path
    }

    /// A rounded ring: `rect` less its inset by `width` (even-odd fill).
    public static func ringPath(_ rect: CGRect, cornerRadius: CGFloat, width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addPath(roundedRect(rect, cornerRadius))
        let inner = rect.insetBy(dx: width, dy: width)
        if inner.width > 0, inner.height > 0 { path.addPath(roundedRect(inner, max(cornerRadius - width, 0))) }
        return path
    }

    /// Four L-shaped brackets of arm `length` at `rect`'s corners.
    public static func bracketsPath(_ rect: CGRect, length: CGFloat) -> CGPath {
        let arm = min(length, rect.width / 2, rect.height / 2)
        let path = CGMutablePath()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1), (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1), (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
        ]
        for (corner, dx, dy) in corners {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        }
        return path
    }

    /// A continuous-looking rounded rect path, the radius clamped to fit.
    public static func roundedRect(_ rect: CGRect, _ cornerRadius: CGFloat) -> CGPath {
        let radius = max(min(cornerRadius, rect.width / 2, rect.height / 2), 0)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
