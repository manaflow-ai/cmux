import AppKit
import CmuxNextDesign

// The flush corner's goo value (`chrome.cornerFlush` = `flush-goo`): the selected tab, which runs down
// into the card, meets the card's top edge through two concave fillets, each tangent to the tab's side
// and to the card's edge, so the two read as one surface that flowed together. No fillet on the side
// that sits on the card's own edge (the first tab), where the card's side continues the tab's.
extension TabCell {
    func layoutCornerFeet() {
        let radius = CornerFlush.current.feetRadius
        guard runsIntoCard, radius > 0 else {
            cornerFeetLayer?.path = nil
            return
        }
        let feet: CAShapeLayer
        if let made = cornerFeetLayer {
            feet = made
        } else {
            feet = CAShapeLayer()
            feet.actions = ["path": NSNull(), "fillColor": NSNull(), "position": NSNull(), "bounds": NSNull()]
            themeScope.perform { feet.fillColor = (Palette.folderTabFill ?? Palette.selectionFill).cgColor }
            layer.insertSublayer(feet, below: backgroundLayer)
            cornerFeetLayer = feet
        }
        feet.frame = layer.bounds
        feet.path = Self.feetPath(pill: backgroundLayer.frame, radius: radius, skipsLeading: cornerFeetSkipsLeading)
    }

    /// The folder tab's outline in the cell's layer (flipped: maxY is the card's top): the pill down to the
    /// card, rounded on top only, and its fillets; nil unless the tab runs into the card. The chrome's shade
    /// leaves exactly this out (`CornerFlushChrome`), so the tab shows the content's glass
    /// (``Palette/folderTabFill``). Read from the metrics, not the layers, so it holds in the pass that
    /// selects the tab, before the cell lays out.
    func folderPath() -> CGPath? {
        guard runsIntoCard else { return nil }
        var body = metrics.pillFrame(slotWidth: layer.bounds.width, height: layer.bounds.height)
        body.size.height += cornerFoot
        guard body.width > 0, body.height > 0 else { return nil }
        let r = min(metrics.cornerRadius, body.width / 2, body.height / 2)
        var path = CGPath(roundedRect: body, cornerWidth: r, cornerHeight: r, transform: nil)
            .union(CGPath(rect: CGRect(x: body.minX, y: body.minY + r, width: body.width, height: body.height - r), transform: nil))
        let feet = CornerFlush.current.feetRadius
        if feet > 0 { path = path.union(Self.feetPath(pill: body, radius: feet, skipsLeading: cornerFeetSkipsLeading)) }
        return path
    }

    /// The fillets below a pill whose bottom (maxY, flipped) is the card's top: at each bottom corner a
    /// radius square outside the pill less the circle that rounds it.
    static func feetPath(pill: CGRect, radius r: CGFloat, skipsLeading: Bool) -> CGPath {
        let path = CGMutablePath()
        let bottom = pill.maxY
        for (x, center, leading) in [(pill.minX - r, pill.minX - r, true), (pill.maxX, pill.maxX + r, false)] where !(leading && skipsLeading) {
            let square = CGPath(rect: CGRect(x: x, y: bottom - r, width: r, height: r), transform: nil)
            let circle = CGPath(ellipseIn: CGRect(x: center - r, y: bottom - 2 * r, width: 2 * r, height: 2 * r), transform: nil)
            path.addPath(square.subtracting(circle))
        }
        return path
    }
}
