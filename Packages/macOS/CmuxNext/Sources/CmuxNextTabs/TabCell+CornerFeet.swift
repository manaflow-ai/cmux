import AppKit
import CmuxNextDesign

// The folder tab (design/selected-is-foreground.md; `chrome.cornerFlush` = `flush-goo`, the default).
// Leo, 2026-11-10: "We can like morph it in as like, you know how folder tabs look, right? Like just
// integrate that. Like make it look cohesive." The selected tab is the foreground: one shape in the
// content's own surface (`Palette.selectedFolderSurface`) that rises from the content's top edge, rounded
// on top, and meets that edge through two concave fillets, each tangent to the tab's side and to the
// edge, so the tab and the content read as one surface. No fillet on the side that sits on the
// content's own edge (the first tab), where the content's side continues the tab's.
//
// The shape is one layer, laid out once per geometry change. A selection change only fades its
// opacity (`MotionFade.crossfade`, 80 ms; instant under Reduce Motion's ceiling), so the shape and its
// color move together, nothing is laid out again and nothing jumps: the old tab's folder fades out as
// the new one's fades in over the same frames.
extension TabCell {
    func layoutCornerFeet() {
        guard cornerFoot > 0 else {
            cornerFeetLayer?.path = nil
            cornerFeetLayer?.opacity = 0
            return
        }
        // A tab that was never selected makes no layer.
        guard runsIntoCard || cornerFeetLayer != nil else { return }
        let folder: CAShapeLayer
        if let made = cornerFeetLayer {
            folder = made
        } else {
            folder = CAShapeLayer()
            folder.actions = ["path": NSNull(), "fillColor": NSNull(), "position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
            // Made hidden: ``updateFolder(animated:)`` shows it, faded in on a first selection like every
            // later one, at once for a layout that puts a selected tab into the card.
            folder.opacity = 0
            themeScope.perform { folder.fillColor = Palette.selectedFolderSurface.cgColor }
            layer.insertSublayer(folder, below: backgroundLayer)
            cornerFeetLayer = folder
        }
        folder.frame = layer.bounds
        folder.path = Self.folderPath(pill: backgroundLayer.frame, foot: cornerFoot, cornerRadius: metrics.cornerRadius,
                                      feetRadius: CornerFlush.current.feetRadius, skipsLeading: cornerFeetSkipsLeading)
    }

    /// Shows the folder while the tab runs into the content, hides it otherwise: faded on a selection
    /// change (`animated`), at once for a lift, a drop or a strip change.
    func updateFolder(animated: Bool) {
        if runsIntoCard, cornerFeetLayer == nil { layoutCornerFeet() }
        guard let folder = cornerFeetLayer else { return }
        let target: Float = runsIntoCard ? 1 : 0
        if animated {
            Motion.tabs.set(folder, "opacity", to: target, fade: .crossfade)
        } else {
            folder.removeAnimation(forKey: "opacity")
            folder.opacity = target
        }
    }

    /// The folder tab in the cell's (flipped) coordinates: the pill's top with its rounded corners,
    /// its sides straight down `foot` past the pill to the content's top edge, and at each bottom
    /// corner a concave fillet of `feetRadius` (none when 0), the leading one left out when
    /// `skipsLeading`. One path, so no seam shows between the body and its fillets.
    static func folderPath(pill: CGRect, foot: CGFloat, cornerRadius: CGFloat, feetRadius: CGFloat, skipsLeading: Bool) -> CGPath {
        let top = pill.minY, bottom = pill.maxY + foot
        let r = max(0, min(cornerRadius, pill.width / 2, (bottom - top) / 2))
        let body = CGMutablePath()
        body.move(to: CGPoint(x: pill.minX, y: bottom))
        body.addLine(to: CGPoint(x: pill.minX, y: top + r))
        body.addArc(tangent1End: CGPoint(x: pill.minX, y: top), tangent2End: CGPoint(x: pill.minX + r, y: top), radius: r)
        body.addLine(to: CGPoint(x: pill.maxX - r, y: top))
        body.addArc(tangent1End: CGPoint(x: pill.maxX, y: top), tangent2End: CGPoint(x: pill.maxX, y: top + r), radius: r)
        body.addLine(to: CGPoint(x: pill.maxX, y: bottom))
        body.closeSubpath()
        guard feetRadius > 0 else { return body }
        let base = CGRect(x: pill.minX, y: top, width: pill.width, height: bottom - top)
        return body.union(feetPath(pill: base, radius: feetRadius, skipsLeading: skipsLeading))
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
