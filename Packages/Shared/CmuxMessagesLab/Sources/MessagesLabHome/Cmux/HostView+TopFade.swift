import AppKit

/// cmux (Lawrence 2026-10-23, "make variations of how we do fade at top in chief"): the chat's top
/// under the avatar and the "Chief >" pill, one ``HomeTopFadeStyle`` at a time, switchable live.
/// A style is the rows' mask on the transcript clip (`MessagesWindowView.topMaskStops`), at most one
/// band over the rows (`HeaderGlassView`, `HomeTopFadeView` or Messages' `HeaderBackdropView`), or
/// both. Nothing changes per scrolled frame but the edge shadow's on/off.
extension HostView {
    /// Applies `style` (a no-op when it is the current one and nothing it depends on changed).
    /// Not for a pane with no header (`useBareTop`), which keeps its own fade.
    func applyTopFadeStyle(_ style: HomeTopFadeStyle) {
        guard !bareTop else { return }
        let rt = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if topFadeStyle == style, topFadeView?.reducedTransparency ?? rt == rt {
            applyTopFadeColors()
            return
        }
        topFadeStyle = style
        // Tear down the last style's band.
        headerGlass?.removeFromSuperview()
        headerGlass = nil
        topFadeView?.removeFromSuperview()
        topFadeView = nil
        headerBackdrop.isHidden = true
        switch style {
        case .glassBand:
            useHeaderGlass()
        case .messagesBar:
            headerBackdrop.isHidden = false
        case .progressiveBlur, .materialHairline, .edgeShadow, .backgroundTint:
            let v = HomeTopFadeView(style: style)
            addSubview(v, positioned: .below, relativeTo: paneHeader)
            topFadeView = v
        case .softMask, .belowPill:
            break
        }
        applyTopFadeColors()
        demo?.topMaskStops = Self.topMaskStops(for: style, clearBackground: Fixture.background.alphaComponent < 0.5)
        needsLayout = true
        updateTopFadeScrollEdge()
    }

    /// The rows' alpha under the pane's top for `style` (y down from the pane's top; empty: full strength).
    static func topMaskStops(for style: HomeTopFadeStyle, clearBackground: Bool) -> [(y: CGFloat, alpha: CGFloat)] {
        let pill = HomeTopFadeView.pillBottom
        switch style {
        case .glassBand, .materialHairline, .messagesBar:
            return []
        case .softMask:
            // Eased (smoothstep) from nothing at 8 pt to full 24 pt under the pill: the text under the
            // avatar is a whisper, under the pill a half tone, never a cut line.
            return easedRamp(from: 8, to: pill + 24)
        case .progressiveBlur:
            // The blur does the work; only the top 20 pt fades, so nothing sits sharp at the window's edge.
            return easedRamp(from: 0, to: 20)
        case .edgeShadow:
            return [(y: pill, alpha: 0), (y: pill, alpha: 1)]
        case .belowPill:
            return [(y: CGFloat(0), alpha: CGFloat(0))] + easedRamp(from: pill, to: pill + 28)
        case .backgroundTint:
            // The tint covers the rows; a see-through window has no background to tint with, so it fades the rows instead.
            return clearBackground ? easedRamp(from: 8, to: pill + 24) : []
        }
    }

    private static func easedRamp(from a: CGFloat, to b: CGFloat) -> [(y: CGFloat, alpha: CGFloat)] {
        (0...6).map { i in
            let t = CGFloat(i) / 6
            return (a + (b - a) * t, t * t * (3 - 2 * t))
        }
    }

    /// The bands' colours from the theme (`Fixture.background`, `Fixture.lightAppearance`).
    func applyTopFadeColors() {
        topFadeView?.applyColors(background: Fixture.background, light: Fixture.lightAppearance)
        if topFadeStyle == .messagesBar {
            headerBackdrop.setTint(Fixture.background)
            headerBackdrop.setLight(Fixture.lightAppearance)
        }
    }

    /// Follows the pane's width (called from `placeNativeViews`).
    func placeTopFadeView() {
        // The transcript can arrive after the style (a pane installed later): its mask follows here.
        if let demo, let style = topFadeStyle, !bareTop {
            demo.topMaskStops = Self.topMaskStops(for: style, clearBackground: Fixture.background.alphaComponent < 0.5)
        }
        guard let topFadeView else { return }
        let frame = CGRect(x: 0, y: 0, width: bounds.width, height: topFadeView.height)
        if topFadeView.frame != frame { topFadeView.frame = frame }
    }

    /// The edge shadow shows only while rows sit above the cut (scrolled up from the oldest row).
    func updateTopFadeScrollEdge() {
        guard let topFadeView, topFadeView.style == .edgeShadow, let demo else { return }
        let oldestRowY = demo.windowY(contentY: demo.layout.rowsTop)
        topFadeView.setScrolledUnder(oldestRowY < HomeTopFadeView.pillBottom - 0.5)
    }
}
