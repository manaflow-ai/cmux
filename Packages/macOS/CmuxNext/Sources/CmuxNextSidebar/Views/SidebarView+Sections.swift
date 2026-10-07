import AppKit
import CmuxNextDesign

// Pinned item sections above and below the workspace list
// (plans/cmux-next/sidebar-sections.md). The footer section
// (`SidebarLayoutDocument.bottomSectionID`: the profile control, with the
// space dots in its row) is outside the capped, scrolling band below the
// list: it is pinned at the sidebar's bottom, so a tall bottom section (the
// Chats section) scrolls above it and never pushes it out of view.
extension SidebarView {
    /// Every region that draws layout items, the footer first.
    var bandRegions: [SidebarRegionView] { [footerRegion, belowRegion, aboveRegion] }

    func buildBands() {
        for (scroll, region) in [(aboveScroll, aboveRegion), (belowScroll, belowRegion)] {
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            SystemScrollers.follow(scroll)
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentView.drawsBackground = false
            scroll.verticalScrollElasticity = .none
            scroll.documentView = region
        }
        for region in bandRegions {
            region.liftHost = self
            region.onActivateWithModifiers = { [weak self, weak region] id, flags in
                // The profile control opens its menu over itself.
                if let view = region?.itemView(id), view.showsAvatar, self?.showProfileMenu(from: view) == true { return }
                self?.model.send(.activateItem(id, opensWorkspace: flags.contains(.option)))
            }
            region.onToggleSection = { [weak self] id in self?.model.send(.toggleLayoutSection(id)) }
            // A drop gives the layout the order the band showed (R77).
            region.onReorder = { [weak self] subject, shown in
                guard let self, let op = SidebarRegionReorder.op(for: subject, shown: shown, document: self.model.layout) else { return }
                self.model.send(.layout(op))
            }
        }
        SidebarPinDrops.install(self)
        // The footer row (the profile control and the spaces dots) takes no
        // drag and drop for now (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 3).
        // The band below keeps the same rule it had while it held the footer.
        footerRegion.allowsDrag = false
        belowRegion.allowsDrag = false
        aboveFade = ScrollEdgeFadeView(scrollView: aboveScroll)
        belowFade = ScrollEdgeFadeView(scrollView: belowScroll)
        addSubview(aboveFade)
        addSubview(belowFade)
        addSubview(footerRegion)
        wantsLayer = true
        aboveLine.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(aboveLine)
        installCardStack()
    }

    /// Gives the three regions their sections: the band above the list,
    /// the band below it without the footer section, and the footer section
    /// alone (when it is in the band below).
    func updateBands() {
        let width = bounds.width
        let hidden = Set(model.resolvedItemInfo.filter(\.value.isHidden).keys)
        let (above, below) = model.layout.bands(room: model.activeProfileID?.rawValue)
        let apps = model.suppressedApps
        let shownAbove = (model.transientTopSection.map { [$0] } ?? []) + above.presenting(hidingItems: hidden, apps: apps)
        let shownBelow = below.presenting(hidingItems: hidden, apps: apps)
        let isFooter = { (section: LayoutSection) in section.id == SidebarLayoutDocument.bottomSectionID }
        let look = SidebarSectionTunables.currentLook
        let metrics = SidebarRegionMetrics.standard
        // The one selection marks its top item active (its glyph, accessibility).
        var selectedInfos = model.resolvedItemInfo
        for transient in model.transientTopItems { selectedInfos[transient.item.id] = transient.info }
        for id in selectedInfos.keys { selectedInfos[id]?.isActive = model.selectedItem == .topItem(id) }
        func content(_ sections: [LayoutSection]) -> SidebarRegionView.Content {
            SidebarRegionView.Content(sections: sections.map(titled), infos: selectedInfos, collapsed: model.collapsedLayoutSections,
                                      look: look, metrics: metrics, drawsLines: Borders.drawsLines, appHeights: appHeights(sections, width: width))
        }
        aboveRegion.update(content(shownAbove), width: width)
        belowRegion.update(content(shownBelow.filter { !isFooter($0) }), width: width)
        footerRegion.update(content(shownBelow.filter(isFooter)), width: width)
    }

    /// Lays out the bands between `top` and the bottom: the pinned footer
    /// section at the bottom, `footerHeight` (dots, cards) above the band
    /// below the list; returns the list's frame between the bands. Call
    /// `updateBands()` first.
    func layoutBands(top y: CGFloat, footerHeight: CGFloat) -> NSRect {
        let b = bounds
        // The footer section takes its full height, never capped or scrolled.
        let pinned = footerRegion.layoutResult.height
        footerRegion.frame = NSRect(x: 0, y: b.height - pinned, width: b.width, height: pinned)
        // Pinned item sections above and below the list, each capped at
        // its share of the height (then it scrolls inside).
        let available = max(0, b.height - y - footerHeight - pinned)
        let look = SidebarSectionTunables.currentLook
        let (aboveHeight, belowHeight) = SidebarBandHeights.resolve(
            above: aboveRegion.layoutResult, below: belowRegion.layoutResult, available: available,
            preferences: DesignSettings.shared.sidebarSections, minimumList: Metrics.sidebarRowHeight * 3,
            bandFloor: Metrics.sidebarRowHeight + Metrics.space2)
        aboveFade.frame = NSRect(x: 0, y: y, width: b.width, height: aboveHeight)
        size(aboveRegion, in: aboveScroll, width: b.width)
        // The band below sits on the footer section; the dots and cards go above it.
        belowFade.frame = NSRect(x: 0, y: footerRegion.frame.minY - belowHeight, width: b.width, height: belowHeight)
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
