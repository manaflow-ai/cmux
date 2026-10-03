import AppKit
import CmuxNextDesign

// Sticky item sections above and below the workspace list
// (plans/cmux-next/sidebar-sections.md), or none while `window.rail` shows
// them as the rail.
extension SidebarView {
    func buildBands() {
        for (scroll, region) in [(aboveScroll, aboveRegion), (belowScroll, belowRegion)] {
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentView.drawsBackground = false
            scroll.verticalScrollElasticity = .none
            scroll.documentView = region
            region.onActivate = { [weak self] id in self?.model.send(.activateItem(id)) }
            region.onToggleSection = { [weak self] id in self?.model.send(.toggleLayoutSection(id)) }
        }
        aboveFade = ScrollEdgeFadeView(scrollView: aboveScroll)
        belowFade = ScrollEdgeFadeView(scrollView: belowScroll)
        addSubview(aboveFade)
        addSubview(belowFade)
        wantsLayer = true
        for line in [aboveLine, belowLine] {
            line.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            layer?.addSublayer(line)
        }
    }

    /// Lays out both bands between `top` and the footer; returns the
    /// list's frame between them.
    func layoutBands(top y: CGFloat, footerHeight: CGFloat) -> NSRect {
        let b = bounds
        // Sticky item sections above and below the list, each capped at
        // its share of the height (then it scrolls inside).
        let available = max(0, b.height - y - footerHeight)
        let hidden = Set(model.itemInfo.filter(\.value.isHidden).keys)
        // `window.rail` draws the sticky sections in the rail instead; the
        // sidebar keeps only its workspace list.
        let (above, below) = DesignSettings.shared.rail == .off
            ? model.layout.bands(room: model.activeProfileID?.rawValue) : ([], [])
        let apps = model.suppressedApps
        let bands = (above: above.presenting(hidingItems: hidden, apps: apps), below: below.presenting(hidingItems: hidden, apps: apps))
        let look = SidebarSectionTunables.currentLook
        let metrics = SidebarRegionMetrics.standard
        func content(_ sections: [LayoutSection]) -> SidebarRegionView.Content {
            SidebarRegionView.Content(sections: sections, infos: model.itemInfo, collapsed: model.collapsedLayoutSections,
                                      look: look, metrics: metrics, drawsLines: Borders.drawsLines)
        }
        aboveRegion.update(content(bands.above), width: b.width)
        belowRegion.update(content(bands.below), width: b.width)
        let (aboveHeight, belowHeight) = SidebarBandHeights.resolve(
            above: aboveRegion.layoutResult, below: belowRegion.layoutResult, available: available,
            preferences: DesignSettings.shared.sidebarSections, minimumList: Metrics.sidebarRowHeight * 3,
            bandFloor: Metrics.sidebarRowHeight + Metrics.space2)
        aboveFade.frame = NSRect(x: 0, y: y, width: b.width, height: aboveHeight)
        size(aboveRegion, in: aboveScroll, width: b.width)
        belowFade.frame = NSRect(x: 0, y: b.height - footerHeight - belowHeight, width: b.width, height: belowHeight)
        size(belowRegion, in: belowScroll, width: b.width)
        let listY = y + aboveHeight
        layoutBandLines(aboveY: listY, belowY: belowFade.frame.minY, look: look,
                        showsAbove: aboveHeight > 0, showsBelow: belowHeight > 0)
        return NSRect(x: 0, y: listY, width: b.width, height: max(0, available - aboveHeight - belowHeight))
    }

    /// Sizes a band's document; when its height changes the band shows its
    /// top again (a stale offset would leave the top fade on).
    private func size(_ region: SidebarRegionView, in scroll: NSScrollView, width: CGFloat) {
        let height = region.layoutResult.height
        guard region.frame.size != NSSize(width: width, height: height) else { return }
        let grew = region.frame.height != height
        region.frame = NSRect(x: 0, y: 0, width: width, height: height)
        if grew {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// The hairlines under the band above and over the band below (the
    /// quiet and lines looks); `appearance.borders` none hides them.
    private func layoutBandLines(aboveY: CGFloat, belowY: CGFloat, look: SectionsLookVariant, showsAbove: Bool, showsBelow: Bool) {
        let width = Metrics.dividerThickness
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        aboveLine.frame = NSRect(x: 0, y: aboveY - width, width: bounds.width, height: width)
        belowLine.frame = NSRect(x: 0, y: belowY, width: bounds.width, height: width)
        aboveLine.isHidden = !(look.drawsBandLines && showsAbove)
        belowLine.isHidden = !(look.drawsBandLines && showsBelow)
        performWithTheme {
            aboveLine.backgroundColor = Palette.separator.cgColor
            belowLine.backgroundColor = Palette.separator.cgColor
        }
        CATransaction.commit()
    }
}
