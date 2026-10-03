public import CoreGraphics

/// Where a drop lands relative to its region.
public nonisolated enum DropOverlayZone: String, Sendable, Hashable, CaseIterable {
    case center, left, right, top, bottom
    /// Between columns (a new strip column).
    case column

    init(_ target: DropTarget) {
        switch target {
        case .newColumn: self = .column
        case let .newDock(_, edge): self = edge == .top ? .top : .bottom
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

    public init(target: CGRect, finalTarget: CGRect? = nil, region: CGRect, zone: DropOverlayZone, bounds: CGRect,
                cornerRadius: CGFloat, label: String, showsLabel: Bool) {
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

/// Pure geometry of the overlay styles (flipped coordinates: y grows down),
/// unit-tested without AppKit.
public nonisolated enum DropOverlayGeometry {
    /// The two panes a split creates inside `region`: the incoming one on
    /// the zone's side and the existing one, each giving up half of `gap`.
    /// A center or column drop creates no second pane.
    public static func splitPreview(region: CGRect, zone: DropOverlayZone, gap: CGFloat) -> (incoming: CGRect, existing: CGRect?) {
        let half = max(gap, 0) / 2
        switch zone {
        case .left, .right:
            let width = max(region.width / 2 - half, 0)
            let leading = CGRect(x: region.minX, y: region.minY, width: width, height: region.height)
            let trailing = CGRect(x: region.maxX - width, y: region.minY, width: width, height: region.height)
            return zone == .left ? (leading, trailing) : (trailing, leading)
        case .top, .bottom:
            let height = max(region.height / 2 - half, 0)
            let upper = CGRect(x: region.minX, y: region.minY, width: region.width, height: height)
            let lower = CGRect(x: region.minX, y: region.maxY - height, width: region.width, height: height)
            return zone == .top ? (upper, lower) : (lower, upper)
        case .center, .column:
            return (region, nil)
        }
    }

    /// The insertion caret: on the line where the new divider appears for
    /// a split, along the tab strip (top edge) for a center drop, and down
    /// the middle of a column gap. `length` is a share of that edge.
    public static func insertionLine(region: CGRect, zone: DropOverlayZone, width: CGFloat, length: CGFloat) -> CGRect {
        let share = min(max(length, 0), 1)
        switch zone {
        case .left, .right, .column:
            let height = region.height * share
            return CGRect(x: region.midX - width / 2, y: region.midY - height / 2, width: width, height: height)
        case .top, .bottom:
            let span = region.width * share
            return CGRect(x: region.midX - span / 2, y: region.midY - width / 2, width: span, height: width)
        case .center:
            let span = region.width * share
            return CGRect(x: region.midX - span / 2, y: region.minY + width, width: span, height: width)
        }
    }

    /// Edges a glow grows from: the side the new pane takes, every edge
    /// for a center drop or a column gap.
    public static func glowEdges(_ zone: DropOverlayZone) -> [CGRectEdge] {
        switch zone {
        case .left: [.minXEdge]
        case .right: [.maxXEdge]
        case .top: [.minYEdge]
        case .bottom: [.maxYEdge]
        case .center, .column: [.minXEdge, .maxXEdge, .minYEdge, .maxYEdge]
        }
    }

    /// A band of `depth` along `edge` of `rect` (flipped: minY is the top).
    public static func band(_ rect: CGRect, edge: CGRectEdge, depth: CGFloat) -> CGRect {
        let depth = min(max(depth, 0), edge == .minXEdge || edge == .maxXEdge ? rect.width : rect.height)
        return rect.divided(atDistance: depth, from: edge).slice
    }

    /// A card of `fraction` of the target's width (at most `maxWidth`) and
    /// `height`, centered in it and never larger than it.
    public static func insetCard(target: CGRect, fraction: CGFloat, maxWidth: CGFloat, height: CGFloat) -> CGRect {
        let width = min(target.width * min(max(fraction, 0), 1), maxWidth, target.width)
        let cardHeight = min(height, target.height)
        return CGRect(x: target.midX - width / 2, y: target.midY - cardHeight / 2, width: width, height: cardHeight)
    }

    /// The tab pill at the target's top leading corner, inset by `inset`,
    /// `width` wide (at most the target's width less the insets).
    public static func tabPill(target: CGRect, width: CGFloat, height: CGFloat, inset: CGFloat) -> CGRect {
        let pillWidth = max(min(width, target.width - inset * 2), 0)
        let pillHeight = max(min(height, target.height - inset * 2), 0)
        return CGRect(x: target.minX + inset, y: target.minY + inset, width: pillWidth, height: pillHeight)
    }

    /// The card a morph starts from: centered on the pointer, `width` wide
    /// with a 3:2 aspect.
    public static func morphStart(pointer: CGPoint, width: CGFloat) -> CGRect {
        let height = (width * 2 / 3).rounded()
        return CGRect(x: pointer.x - width / 2, y: pointer.y - height / 2, width: width, height: height)
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
