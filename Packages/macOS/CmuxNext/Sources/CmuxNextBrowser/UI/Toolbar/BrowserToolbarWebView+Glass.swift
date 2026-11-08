import AppKit
import CmuxNextDesign

// `browser.omnibar.glass` `regular` or `clear` (OmnibarViews' material): Liquid Glass (or the older
// material) under the page's bar, at the rect the page reported for it, with the look's corner
// radius, tint (`glassTint`, `glassTintStrength`; a stronger tint while editing) and `shadow`. The
// page then draws no flat fill over it (`look.glass`), only the hover lift, the focus ring and the
// card top, which hides the glass. Reduce Transparency draws the flat fill instead.
extension BrowserToolbarWebView {
    /// Whether the bar draws glass now (the look asks for it and transparency is not reduced).
    var drawsBarGlass: Bool {
        let material = OmnibarGlassLook.current.material
        return (material == .regular || material == .clear) && !ReduceTransparency.shared.isEnabled
    }

    /// Places, tints and shows (or hides and drops) the glass under the bar: after each layout
    /// report, status change and push.
    func updateBarGlass() {
        let look = OmnibarGlassLook.current
        guard drawsBarGlass else {
            barGlass?.removeFromSuperview()
            barGlass = nil
            return
        }
        guard let rect = layoutReport.rects["omnibar"], !status.isPopupOpen, content != nil else {
            barGlass?.isHidden = true
            return
        }
        let style: Glass.Style = look.material == .clear ? .clear : .regular
        let host = barGlass ?? makeBarGlass(style)
        guard let glass = host.subviews.first as? GlassPanelView else { return }
        let radius = look.resolvedCornerRadius(barHeight: rect.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.isHidden = false
        if host.frame != rect { host.frame = rect }
        glass.frame = host.bounds
        if glass.style != style { glass.style = style }
        glass.cornerRadius = radius
        performWithTheme {
            glass.tintColor = look.tintColor(boost: status.isEditing ? 0.15 : 0)
            host.layer?.shadowColor = Palette.shadow.cgColor
        }
        if look.shadow {
            // The raised elevation step (PopupStyle.elevation2), as every floating surface.
            let elevation = PopupStyle.elevation2
            host.layer?.shadowOpacity = Float(elevation.alpha)
            host.layer?.shadowRadius = elevation.layerRadius
            host.layer?.shadowOffset = elevation.layerOffset(flipped: true)
            host.layer?.shadowPath = CGPath(roundedRect: host.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        } else {
            host.layer?.shadowOpacity = 0
            host.layer?.shadowPath = nil
        }
        CATransaction.commit()
    }

    private func makeBarGlass(_ style: Glass.Style) -> NSView {
        let host = NSView()
        host.wantsLayer = true
        host.translatesAutoresizingMaskIntoConstraints = true
        host.setAccessibilityElement(false)
        let glass = GlassPanelView(style: style, cornerRadius: 0) // glass-level-allow: the omnibar's material and tint are the browser.omnibar look setting (OmnibarGlassLook), not a fixed level
        glass.translatesAutoresizingMaskIntoConstraints = true
        host.addSubview(glass)
        // Under the page, which draws the bar's text, chip and badges over it.
        addSubview(host, positioned: .below, relativeTo: content?.view)
        barGlass = host
        return host
    }
}

extension OmnibarGlassLook {
    /// The glass tint in the active theme scope (read inside `performWithTheme`): the theme's
    /// background, or its accent only when the theme names one (else its neutral focus gray).
    // theme-scoped: its one caller (updateBarGlass) runs it inside performWithTheme
    @MainActor func tintColor(boost: Double = 0) -> NSColor? {
        let base: NSColor
        switch tint {
        case .none: return nil
        case .background: base = Palette.chromeBackground
        case .accent: base = Palette.hasThemeAccent ? Palette.highlight : Palette.focusRing
        }
        let alpha = min(max(tintStrength + boost, 0), 1)
        return base.withAlphaComponent(base.alphaComponent * CGFloat(alpha))
    }
}
