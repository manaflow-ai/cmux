import AppKit
import CmuxNextDesign

// Pinned item sections above and below the workspace list
// (plans/cmux-next/sidebar-sections.md).
extension SidebarView {
    func buildBands() {
        for (scroll, region) in [(aboveScroll, aboveRegion), (belowScroll, belowRegion)] {
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            SystemScrollers.follow(scroll)
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentView.drawsBackground = false
            scroll.verticalScrollElasticity = .none
            scroll.documentView = region
            region.liftHost = self
            region.onActivateWithModifiers = { [weak self] id, flags in
                self?.model.send(.activateItem(id, opensWorkspace: flags.contains(.option)))
            }
            region.onToggleSection = { [weak self] id in self?.model.send(.toggleLayoutSection(id)) }
            // A drop gives the layout the order the band showed (R77).
            region.onReorder = { [weak self] subject, shown in
                guard let self, let op = SidebarRegionReorder.op(for: subject, shown: shown, document: self.model.layout) else { return }
                self.model.send(.layout(op))
            }
        }
        aboveFade = ScrollEdgeFadeView(scrollView: aboveScroll)
        belowFade = ScrollEdgeFadeView(scrollView: belowScroll)
        addSubview(aboveFade)
        addSubview(belowFade)
        wantsLayer = true
        aboveLine.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(aboveLine)
        installCardStack()
    }

    /// Lays out both bands between `top` and the footer; returns the
    /// list's frame between them.
    func layoutBands(top y: CGFloat, footerHeight: CGFloat) -> NSRect {
        let b = bounds
        // Pinned item sections above and below the list, each capped at
        // its share of the height (then it scrolls inside).
        let available = max(0, b.height - y - footerHeight)
        let hidden = Set(model.itemInfo.filter(\.value.isHidden).keys)
        let (above, below) = model.layout.bands(room: model.activeProfileID?.rawValue)
        let apps = model.suppressedApps
        let bands = (above: above.presenting(hidingItems: hidden, apps: apps), below: below.presenting(hidingItems: hidden, apps: apps))
        let look = SidebarSectionTunables.currentLook
        let metrics = SidebarRegionMetrics.standard
        func content(_ sections: [LayoutSection]) -> SidebarRegionView.Content {
            SidebarRegionView.Content(sections: sections.map(titled), infos: model.itemInfo, collapsed: model.collapsedLayoutSections,
                                      look: look, metrics: metrics, drawsLines: Borders.drawsLines, appHeights: appHeights(sections, width: b.width))
        }
        aboveRegion.update(content(bands.above), width: b.width)
        belowRegion.update(content(bands.below), width: b.width)
        let (aboveHeight, belowHeight) = SidebarBandHeights.resolve(
            above: aboveRegion.layoutResult, below: belowRegion.layoutResult, available: available,
            preferences: DesignSettings.shared.sidebarSections, minimumList: Metrics.sidebarRowHeight * 3,
            bandFloor: Metrics.sidebarRowHeight + Metrics.space2)
        aboveFade.frame = NSRect(x: 0, y: y, width: b.width, height: aboveHeight)
        size(aboveRegion, in: aboveScroll, width: b.width)
        // The Settings band sits at the bottom; the dots and cards go above it.
        belowFade.frame = NSRect(x: 0, y: b.height - belowHeight, width: b.width, height: belowHeight)
        size(belowRegion, in: belowScroll, width: b.width)
        let listY = y + aboveHeight
        layoutBandLine(aboveY: listY, look: look, showsAbove: aboveHeight > 0)
        return NSRect(x: 0, y: listY, width: b.width, height: max(0, available - aboveHeight - belowHeight))
    }

    /// An app section without its own title takes the provider's title.
    private func titled(_ section: LayoutSection) -> LayoutSection {
        guard section.content == .app, section.title == nil, let contribution = section.contribution else { return section }
        var section = section
        section.title = appSections?.title(for: contribution)
        return section
    }

    /// Content heights of the app sections that have a view (presented apps).
    private func appHeights(_ sections: [LayoutSection], width: CGFloat) -> [LayoutSectionID: CGFloat] {
        guard let provider = appSections else { return [:] }
        var heights: [LayoutSectionID: CGFloat] = [:]
        for section in sections where section.content == .app {
            guard let contribution = section.contribution, provider.makeView(for: contribution) != nil else { continue }
            heights[section.id] = max(provider.preferredHeight(for: contribution, width: width), Metrics.sidebarRowHeight)
        }
        return heights
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

    /// The hairline under the band above (the quiet and lines looks);
    /// `appearance.borders` none hides it. The footer has no line over it
    /// (SIDEBAR-FOOTER-MINIMAL).
    private func layoutBandLine(aboveY: CGFloat, look: SectionsLookVariant, showsAbove: Bool) {
        let width = Metrics.dividerThickness
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        aboveLine.frame = NSRect(x: 0, y: aboveY - width, width: bounds.width, height: width)
        aboveLine.isHidden = !(look.drawsBandLines && showsAbove)
        performWithTheme { aboveLine.backgroundColor = Palette.separator.cgColor }
        CATransaction.commit()
    }

    /// Puts the card stack (R114) in the sidebar and returns its height.
    func attachFooterCards() -> CGFloat {
        guard let cards = footerCards else { return 0 }
        if cards.superview !== self { addSubview(cards) }
        return cards.isHidden ? 0 : cards.fittingSize.height
    }

    func layoutFooter(_ slots: [(SidebarAccessorySlot, NSView)]) {
        let f = footer.bounds
        // Account and cloud lead; status fills the remaining space. Help is
        // in the Help menu and the account menu, not here
        // (SIDEBAR-FOOTER-MINIMAL).
        let side = Metrics.sidebarRowHeight
        var x = Metrics.space4
        for (slot, view) in slots {
            let width: CGFloat = switch slot {
            case .account, .cloud: side
            case .status: max(0, f.width - x - Metrics.space4)
            }
            view.frame = NSRect(x: x, y: (f.height - side) / 2, width: width, height: side)
            x += width + Metrics.space2
        }
    }

    /// A space switch (R99): after a swipe the real list takes the page's
    /// place; else the old page slides out toward the side away from the new
    /// space's dot (a new space at the end comes in from the trailing edge).
    func switchSpace(from old: ProfileKey?, to new: ProfileKey?, profiles: [SidebarProfile], oldSections: [SidebarSection] = []) {
        if spacePaging.modelDidSwitch(to: new) { return list.reload(animated: false) }
        let oldIndex = profiles.firstIndex { $0.id == old }, newIndex = profiles.firstIndex { $0.id == new }
        guard let oldIndex, let newIndex, oldIndex != newIndex else { return list.reload(animated: false) }
        spacePaging.prepareSlide(oldSections: oldSections)
        list.reload(animated: false)
        spacePaging.slide(direction: SpacePager.direction(from: oldIndex, to: newIndex))
    }
}
