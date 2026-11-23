import CmuxNextDesign
import CoreGraphics

/// How far a pointer's resize of a floating pane reaches: a band on each edge of the card and a square zone at each
/// corner. The band's inner part is in the card (``inside`` points at the top of the bar, the whole rim on the 3
/// other sides) and the rest of it is outside the card's edge, over the panes below. The corner zone is a square
/// from the band's outer corner. At an edge of the pane area the band outside is only the room that is there, and
/// each zone keeps its limits in the card. Coordinates have their origin at the top left.
struct FloatingPaneReach: Equatable {
    /// The part of the band that is inside the card's edge.
    static let inside: CGFloat = 4

    /// The band's width on each edge, and the side of each corner zone (the Floating Pane knobs).
    var band = CGFloat(FloatingPaneTunables.defaultResizeBand)
    var corner = CGFloat(FloatingPaneTunables.defaultCornerZone)

    /// The band outside a card on each of its 4 sides.
    struct Outsets: Equatable {
        var left: CGFloat = 0, top: CGFloat = 0, right: CGFloat = 0, bottom: CGFloat = 0

        /// `card` with its band.
        func grown(_ card: CGRect) -> CGRect {
            CGRect(x: card.minX - left, y: card.minY - top, width: card.width + left + right, height: card.height + top + bottom)
        }

        /// The card in `outer`, a card with its band.
        func card(in outer: CGRect) -> CGRect {
            CGRect(x: outer.minX + left, y: outer.minY + top, width: max(0, outer.width - left - right), height: max(0, outer.height - top - bottom))
        }
    }

    /// The band's width outside a card's edge where there is room for it.
    var outside: CGFloat { max(0, band - Self.inside) }

    /// How far a corner zone goes into the card from each of the card's 2 edges at that corner: the rest of its
    /// side after the band outside, and not less than the rim.
    var cornerInside: CGFloat { max(corner - outside, LayoutFloatingPane.rimWidth) }

    /// The band outside `card` in a pane area `area`: on each side the band's outer part, or the room between the
    /// card and the area's edge when that is less.
    func outsets(of card: CGRect, in area: CGRect) -> Outsets {
        func reach(_ room: CGFloat) -> CGFloat { min(outside, max(0, room)) }
        return Outsets(left: reach(card.minX - area.minX), top: reach(card.minY - area.minY),
                       right: reach(area.maxX - card.maxX), bottom: reach(area.maxY - card.maxY))
    }

    /// The zone at `point` for a card at `card` with the band `outsets`: a corner in the square of that corner, an
    /// edge on the rest of the band, the bar below the top band, and nil in the pane's own rectangle and outside
    /// the band.
    func zone(at point: CGPoint, card: CGRect, outsets: Outsets) -> FloatingPaneCardView.Zone? {
        guard outsets.grown(card).contains(point), !LayoutFloatingPane.paneRect(inCard: card).contains(point) else { return nil }
        let rim = LayoutFloatingPane.rimWidth
        let left = point.x < card.minX + rim, right = point.x >= card.maxX - rim
        let top = point.y < card.minY + Self.inside, bottom = point.y >= card.maxY - rim
        let along = cornerInside
        let nearLeft = point.x < card.minX + along, nearRight = point.x >= card.maxX - along
        let nearTop = point.y < card.minY + along, nearBottom = point.y >= card.maxY - along
        if nearTop && nearLeft { return .topLeft }
        if nearTop && nearRight { return .topRight }
        if nearBottom && nearLeft { return .bottomLeft }
        if nearBottom && nearRight { return .bottomRight }
        if top { return .top }
        if bottom { return .bottom }
        if left { return .left }
        return right ? .right : .move
    }

    /// The rectangles of each zone of a card at `card` with the band `outsets`: the band, the bar and the rim, less
    /// the pane's own rectangle. No two overlap, so each point has one cursor.
    func zoneRects(card: CGRect, outsets: Outsets) -> [(zone: FloatingPaneCardView.Zone, rect: CGRect)] {
        let outer = outsets.grown(card), rim = LayoutFloatingPane.rimWidth, along = cornerInside
        // Each line where the zone can change, held inside the band's outer edge.
        func cuts(_ values: [CGFloat], from low: CGFloat, to high: CGFloat) -> [CGFloat] {
            Set(values.map { min(max($0, low), high) }).sorted()
        }
        let columns = cuts([outer.minX, card.minX + rim, card.minX + along, card.maxX - along, card.maxX - rim, outer.maxX],
                           from: outer.minX, to: outer.maxX)
        let rows = cuts([outer.minY, card.minY + Self.inside, card.minY + LayoutFloatingPane.barHeight, card.minY + along,
                         card.maxY - along, card.maxY - rim, outer.maxY], from: outer.minY, to: outer.maxY)
        var rects: [(zone: FloatingPaneCardView.Zone, rect: CGRect)] = []
        for (minY, maxY) in zip(rows, rows.dropFirst()) {
            // The cells of one row that have the same zone and touch are one rectangle.
            var run: (zone: FloatingPaneCardView.Zone, rect: CGRect)?
            for (minX, maxX) in zip(columns, columns.dropFirst()) {
                let cell = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                let zone = self.zone(at: CGPoint(x: cell.midX, y: cell.midY), card: card, outsets: outsets)
                if let current = run, current.zone == zone {
                    run = (zone: current.zone, rect: current.rect.union(cell))
                    continue
                }
                if let run { rects.append(run) }
                run = zone.map { (zone: $0, rect: cell) }
            }
            if let run { rects.append(run) }
        }
        return rects
    }

    /// `rect` less each of `covers`: the parts of it that no cover hides.
    static func parts(of rect: CGRect, outside covers: [CGRect]) -> [CGRect] {
        covers.reduce([rect]) { parts, cover in
            parts.flatMap { part -> [CGRect] in
                let cut = part.intersection(cover)
                guard !cut.isNull, !cut.isEmpty else { return [part] }
                return [CGRect(x: part.minX, y: part.minY, width: part.width, height: cut.minY - part.minY),
                        CGRect(x: part.minX, y: cut.maxY, width: part.width, height: part.maxY - cut.maxY),
                        CGRect(x: part.minX, y: cut.minY, width: cut.minX - part.minX, height: cut.height),
                        CGRect(x: cut.maxX, y: cut.minY, width: part.maxX - cut.maxX, height: cut.height)].filter { !$0.isEmpty }
            }
        }
    }
}
