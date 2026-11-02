import AppKit
import CmuxNextDesign
import QuartzCore

/// A zoomed pane's indicator on its selected tab (cmux classic's, #25624): the expand glyph in the
/// lit color says the pane fills the workspace, and a click on it restores the layout
/// (`TabStripIntent.toggleZoom`, Toggle Pane Zoom's one path). It draws inside the tab like the
/// speaker, so a zoom never changes the strip's width and no tab moves. Hover and press fills are
/// the speaker's.
extension TabCell {
    static let zoomIconSize: CGFloat = 12
    static let zoomSymbol = "arrow.up.left.and.arrow.down.right"

    func updateZoomBadge() {
        guard showsZoom else {
            zoomLayer?.removeFromSuperlayer()
            zoomBackgroundLayer?.removeFromSuperlayer()
            zoomLayer = nil
            zoomBackgroundLayer = nil
            isZoomHovered = false
            isZoomPressed = false
            return
        }
        guard zoomLayer == nil else { return }
        let fill = CALayer()
        fill.cornerCurve = .continuous
        fill.actions = ["backgroundColor": Self.fade, "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        layer.insertSublayer(fill, below: titleLayer)
        zoomBackgroundLayer = fill
        let icon = CALayer()
        icon.actions = Self.noActions
        icon.contentsGravity = .resizeAspect
        layer.addSublayer(icon)
        zoomLayer = icon
        // `updateColors` colors it next (`applyZoomIcon`).
    }

    /// theme-scoped: callers run it inside `themeScope.perform`.
    func applyZoomIcon() {
        guard let icon = zoomLayer else { return }
        icon.contentsScale = scale
        let tint = isZoomHovered || isZoomPressed ? Palette.textPrimary : Palette.litGlyph
        icon.contents = TabSymbolCache.shared.image(named: Self.zoomSymbol, tint: tint, pointSize: Self.zoomIconSize - 1,
                                                    size: Self.zoomIconSize, scale: scale)
        zoomBackgroundLayer?.backgroundColor = ChromeHover.fillColor(.init(hovering: isZoomHovered, pressed: isZoomPressed))?.cgColor
    }

    /// The indicator's frame in this cell's coordinates while it shows (its hit area), else nil.
    var zoomButtonRect: CGRect? {
        guard let zoomLayer, zoomLayer.opacity > 0, zoomLayer.superlayer != nil else { return nil }
        return zoomLayer.frame
    }

    /// Places the indicator at the end of the title area when the title keeps a few characters;
    /// returns where the title must end.
    func layoutZoomBadge(titleX: CGFloat, titleEnd: CGFloat, midY: CGFloat) -> CGFloat {
        guard let zoomLayer else { return titleEnd }
        let size = Self.zoomIconSize
        guard titleEnd - titleX - size - Metrics.space2 >= 48 else {
            zoomLayer.opacity = 0
            zoomBackgroundLayer?.opacity = 0
            return titleEnd
        }
        let glyph = CGRect(x: pixel(titleEnd - size), y: pixel(midY - size / 2), width: size, height: size)
        zoomLayer.frame = glyph
        zoomLayer.opacity = 1
        if let zoomBackgroundLayer {
            zoomBackgroundLayer.frame = glyph.insetBy(dx: -Self.audioFillOutset, dy: -Self.audioFillOutset)
            zoomBackgroundLayer.cornerRadius = max(0, metrics.cornerRadius - Metrics.space1)
            zoomBackgroundLayer.opacity = 1
        }
        return titleEnd - size - Metrics.space2
    }
}
