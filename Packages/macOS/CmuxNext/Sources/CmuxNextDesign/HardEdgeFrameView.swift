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

    /// The card's cuts: the big one toward the sidebar at the top and its opposite at the bottom.
    @MainActor static func cardCuts(sidebarLeading: Bool) -> HardEdge.Cuts {
        let cuts = HardEdge.Cuts.signature(HardEdge.cardCut, minor: HardEdge.cardMinorCut)
        return sidebarLeading ? cuts : cuts.mirrored
    }

    /// The outline `distance` outside a chamfered rect with `cuts`: each 45° cut stays 45° and
    /// parallel, so its cut grows by `distance × (2 − √2)`.
    static func offset(_ cuts: HardEdge.Cuts, by distance: CGFloat) -> HardEdge.Cuts {
        let grow = distance * (2 - 2.squareRoot())
        return HardEdge.Cuts(topLeading: cuts.topLeading + grow, topTrailing: cuts.topTrailing + grow,
                             bottomTrailing: cuts.bottomTrailing + grow, bottomLeading: cuts.bottomLeading + grow)
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
            // A lit bracket on each big cut, just outside the card's edge: a leg along the edge,
            // the cut, a leg along the other edge, a diamond at the top leg's end.
            let width = (1.5 * scale).rounded() / scale, distance = width / 2 + 1 / scale
            let rect = card.insetBy(dx: -distance, dy: -distance), lit = Self.offset(cuts, by: distance)
            let points = HardEdge.outline(rect, cuts: lit, flipped: false)
            let leg = Metrics.scale(28)
            // outline order: [0,1] top edge, [2,3] trailing edge, [4,5] bottom edge, [6,7] leading edge.
            let topLeading = sidebarLeading
            let (a, b) = topLeading ? (points[7], points[0]) : (points[1], points[2]) // the top cut
            let (c, d) = topLeading ? (points[3], points[4]) : (points[5], points[6]) // the bottom cut
            let dir: CGFloat = topLeading ? 1 : -1
            marksPath.move(to: CGPoint(x: a.x, y: a.y - leg))
            marksPath.addLine(to: a)
            marksPath.addLine(to: b)
            marksPath.addLine(to: CGPoint(x: b.x + dir * leg, y: b.y))
            marksPath.move(to: CGPoint(x: c.x, y: c.y + leg))
            marksPath.addLine(to: c)
            marksPath.addLine(to: d)
            marksPath.addLine(to: CGPoint(x: d.x - dir * leg, y: d.y))
            rivetsPath.addPath(HardEdge.diamond(CGPoint(x: b.x + dir * (leg + Metrics.scale(5)), y: b.y), radius: HardEdge.diamondRadius - 0.5))
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
