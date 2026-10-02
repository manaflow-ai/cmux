import AppKit
import CmuxNextDesign

// Sticky item sections above and below the workspace list
// (plans/cmux-next/sidebar-sections.md).
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
            addSubview(scroll)
        }
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
        let bands = model.layout.bands(room: model.activeProfileID?.rawValue)
        let look = SidebarSectionTunables.currentLook
        let metrics = SidebarRegionMetrics.standard
        func content(_ sections: [LayoutSection]) -> SidebarRegionView.Content {
            SidebarRegionView.Content(sections: sections, infos: model.itemInfo, collapsed: model.collapsedLayoutSections,
                                      look: look, metrics: metrics)
        }
        aboveRegion.update(content(bands.above), width: b.width)
        belowRegion.update(content(bands.below), width: b.width)
        let aboveHeight = aboveRegion.layoutResult.stickyHeight(available: available, share: SidebarRegionMetrics.aboveShare)
        let belowHeight = belowRegion.layoutResult.stickyHeight(available: available, share: SidebarRegionMetrics.belowShare)
        aboveScroll.frame = NSRect(x: 0, y: y, width: b.width, height: aboveHeight)
        aboveRegion.frame = NSRect(x: 0, y: 0, width: b.width, height: aboveRegion.layoutResult.height)
        belowScroll.frame = NSRect(x: 0, y: b.height - footerHeight - belowHeight, width: b.width, height: belowHeight)
        belowRegion.frame = NSRect(x: 0, y: 0, width: b.width, height: belowRegion.layoutResult.height)
        let listY = y + aboveHeight
        layoutBandLines(aboveY: listY, belowY: belowScroll.frame.minY, look: look,
                        showsAbove: aboveHeight > 0, showsBelow: belowHeight > 0)
        return NSRect(x: 0, y: listY, width: b.width, height: max(0, available - aboveHeight - belowHeight))
    }

    /// The hairlines under the band above and over the band below; only
    /// the quiet look draws them, and `appearance.borders` none hides them.
    private func layoutBandLines(aboveY: CGFloat, belowY: CGFloat, look: SectionsLookVariant, showsAbove: Bool, showsBelow: Bool) {
        let width = Metrics.dividerThickness
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        aboveLine.frame = NSRect(x: 0, y: aboveY - width, width: bounds.width, height: width)
        belowLine.frame = NSRect(x: 0, y: belowY, width: bounds.width, height: width)
        aboveLine.isHidden = !(look == .quiet && showsAbove)
        belowLine.isHidden = !(look == .quiet && showsBelow)
        performWithTheme {
            aboveLine.backgroundColor = Palette.separator.cgColor
            belowLine.backgroundColor = Palette.separator.cgColor
        }
        CATransaction.commit()
    }
}
