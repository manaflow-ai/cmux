import AppKit

/// Hard-edge chrome above the content (`MainPaneChromeShadeView`, `chrome.hardEdge`): the shade's
/// corner wedges outside the card's 45° cuts, which opaque content (a terminal, a page) would hide
/// below it, and the value's marks on the frame: `blade` a lit bracket along the two big cuts,
/// `hud` a hairline frame in the gap, parallel to every cut, with diamond rivets. Coordinates are
/// the window root's (unflipped). Takes no clicks.
final class HardEdgeFrameView: NSView {
    private let wedges = CAShapeLayer()
    private let marks = CAShapeLayer()
    private let rivets = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        marks.fillColor = nil
        marks.lineJoin = .miter
        marks.lineCap = .butt
        for sublayer in [wedges, marks, rivets] { layer?.addSublayer(sublayer) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The card's cuts: square under the first tab (toward the sidebar), big top-trailing and bottom-leading.
    @MainActor static func cardCuts(sidebarLeading: Bool) -> HardEdge.Cuts {
        let cuts = HardEdge.Cuts.card(HardEdge.cardCut, minor: HardEdge.cardMinorCut)
        return sidebarLeading ? cuts : cuts.mirrored
    }

    /// The outline `distance` outside a chamfered rect with `cuts`: each 45° cut stays 45° and
    /// parallel, so its cut grows by `distance × (2 − √2)`.
    static func offset(_ cuts: HardEdge.Cuts, by distance: CGFloat) -> HardEdge.Cuts {
        let grow = distance * (2 - CGFloat(2).squareRoot())
        return HardEdge.Cuts(topLeading: cuts.topLeading + grow, topTrailing: cuts.topTrailing + grow,
                             bottomTrailing: cuts.bottomTrailing + grow, bottomLeading: cuts.bottomLeading + grow)
    }

    /// The outline's point pairs (`HardEdge.outline` order) of each big cut: (1, 2) top-trailing,
    /// (3, 4) bottom-trailing, (5, 6) bottom-leading, (7, 0) top-leading.
    @MainActor static func majorCorners(_ cuts: HardEdge.Cuts) -> [(Int, Int)] {
        [(cuts.topTrailing, (1, 2)), (cuts.bottomTrailing, (3, 4)), (cuts.bottomLeading, (5, 6)), (cuts.topLeading, (7, 0))]
            .filter { $0.0 >= HardEdge.cardCut - 0.5 }.map(\.1)
    }

    /// `distance` from `point` toward `target`.
    static func step(from point: CGPoint, toward target: CGPoint, by distance: CGFloat) -> CGPoint {
        let dx = target.x - point.x, dy = target.y - point.y, length = max(hypot(dx, dy), 0.001)
        return CGPoint(x: point.x + dx / length * distance, y: point.y + dy / length * distance)
    }

    func update(card: CGRect, alpha: CGFloat, style: HardEdge, sidebarLeading: Bool, above content: NSView?, in root: NSView?) {
        guard style.isOn, let content, let root, content.superview === root, !card.isEmpty else {
            isHidden = true
            return
        }
        if superview !== root || root.subviews.firstIndex(of: self) != (root.subviews.firstIndex(of: content) ?? 0) + 1 {
            root.addSubview(self, positioned: .above, relativeTo: content)
        }
        frame = root.bounds
        isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for sublayer in [wedges, marks, rivets] { sublayer.frame = bounds }
        let scale = window?.backingScaleFactor ?? 2
        let cuts = Self.cardCuts(sidebarLeading: sidebarLeading)
        let outline = HardEdge.path(card, cuts: cuts, flipped: false)

        // The four corner squares less the card's outline: the wedges outside its cuts.
        let corners = CGMutablePath()
        let side = max(cuts.topLeading, cuts.topTrailing, cuts.bottomLeading, cuts.bottomTrailing)
        for x in [card.minX, card.maxX - side] {
            for y in [card.minY, card.maxY - side] { corners.addRect(CGRect(x: x, y: y, width: side, height: side)) }
        }
        wedges.path = corners.subtracting(outline)
        wedges.fillColor = NSColor.black.withAlphaComponent(alpha).cgColor

        let marksPath = CGMutablePath(), rivetsPath = CGMutablePath()
        switch style {
        case .off, .chamfer:
            break
        case .blade:
            // A lit bracket on each big cut, just outside the card's edge: a leg along each edge
            // and the cut between them; a diamond past the top leg's end.
            let width = (1.5 * scale).rounded() / scale, distance = width / 2 + 1 / scale
            let rect = card.insetBy(dx: -distance, dy: -distance), lit = Self.offset(cuts, by: distance)
            let points = HardEdge.outline(rect, cuts: lit, flipped: false)
            let leg = Metrics.scale(28)
            for corner in Self.majorCorners(cuts) {
                let (a, b) = (points[corner.0], points[corner.1])
                let before = points[(corner.0 + 7) % 8], after = points[(corner.1 + 1) % 8]
                marksPath.move(to: Self.step(from: a, toward: before, by: leg))
                marksPath.addLine(to: a)
                marksPath.addLine(to: b)
                marksPath.addLine(to: Self.step(from: b, toward: after, by: leg))
                if corner.0 == 1 { // the top-trailing cut: a diamond ends its top leg
                    rivetsPath.addPath(HardEdge.diamond(Self.step(from: a, toward: before, by: leg + Metrics.scale(6)),
                                                        radius: HardEdge.diamondRadius - 0.5))
                }
            }
            marks.lineWidth = width
            marks.strokeColor = HardEdge.accent.cgColor
            rivets.fillColor = HardEdge.accent.cgColor
        case .hud:
            // A second frame in the middle of the gap, parallel to every cut; a rivet on each big cut.
            let width = 1 / scale, distance = (HardEdge.gap / 2 * scale).rounded() / scale + width / 2
            let rect = card.insetBy(dx: -distance, dy: -distance), framed = Self.offset(cuts, by: distance)
            marksPath.addPath(HardEdge.path(rect, cuts: framed, flipped: false))
            let points = HardEdge.outline(rect, cuts: framed, flipped: false)
            for (a, b) in [(points[7], points[0]), (points[1], points[2]), (points[3], points[4]), (points[5], points[6])]
                where hypot(b.x - a.x, b.y - a.y) > Metrics.scale(6) {
                rivetsPath.addPath(HardEdge.diamond(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), radius: HardEdge.diamondRadius - 0.5))
            }
            marks.lineWidth = width
            marks.strokeColor = Palette.textTertiary.withAlphaComponent(0.55).cgColor
            rivets.fillColor = Palette.textSecondary.cgColor
        }
        marks.path = marksPath
        rivets.path = rivetsPath
    }
}
