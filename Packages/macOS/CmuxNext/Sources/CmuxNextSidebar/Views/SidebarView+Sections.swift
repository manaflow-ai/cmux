import AppKit
import CmuxNextDesign

// Pinned item sections above and below the workspace list
// (plans/cmux-next/sidebar-sections.md). The footer section
// (`SidebarLayoutDocument.bottomSectionID`: the profile control, with the
// space dots in its row) is outside the capped, scrolling band below the
// list: it is pinned at the sidebar's bottom. The band below the list draws
// nothing since cx-n0i9 (no bottom-left sections; All chats is on the New Tab page).
extension SidebarViewComponents {
    /// Every region that draws layout items, the footer first.
    var bandRegions: [SidebarRegionView] { [footerRegion, belowRegion, aboveRegion] }

    func buildBands() {
        for (scroll, region) in [(aboveScroll, aboveRegion), (belowScroll, belowRegion)] {
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            SystemScrollers.followThin(scroll)
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentView.drawsBackground = false
            scroll.verticalScrollElasticity = .none
            scroll.documentView = region
        }
        for region in bandRegions {
            region.liftHost = self
            wireItems(region)
            // A drop gives the layout the order the band showed (R77).
            region.onReorder = { [weak self] subject, shown in
                guard let self, let op = SidebarRegionReorder.op(for: subject, shown: shown, document: self.model.layout) else { return }
                // On the document a band reorder is one sidebar.move (sidebar-v2 S5).
                if let doc = self.model.docDrag, case let .itemMove(id, section, index) = op {
                    return doc.drop([id.rawValue], SidebarDocDrag.target(section, index: index, moving: [id.rawValue], layout: self.model.layout))
                }
                self.model.send(.layout(op))
            }
        }
        // The sidebar document draws its sections in the list (one renderer); their regions take the same activation and menus.
        list.configureBlockRegion = { [weak self] region in
            guard let self else { return }
            self.wireItems(region)
            // Read the list's provider at right-click time: a block region made before the app set it
            // (the first layout after launch) kept nil, and a pinned workspace's tile opened no menu.
            region.contextMenuProvider = { [weak self] target in self?.list.contextMenuProvider?(target) }
            region.appView = { [weak self] section in section.contribution.flatMap { self?.appSections?.makeView(for: $0) } }
        }
        SidebarPinDrops.install(self)
        // The footer row's items (the profile control) do not drag; its space
        // dots reorder by their own drag, dropped on the footer band
        // (`ProfileBarView+DotDrag`). The band below keeps the rule it had while it held the footer.
        footerRegion.allowsDrag = false
        footerRegion.emptySpaceTarget = .footer
        belowRegion.allowsDrag = false
        addSubview(aboveFade)
        addSubview(belowFade)
        addSubview(footerRegion)
        wantsLayer = true
        aboveLine.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(aboveLine)
    }

    /// A region's item activation and section folding (the bands and the list's blocks).
    private func wireItems(_ region: SidebarRegionView) {
        region.onCloseWorkspace = { [weak self] workspace in self?.model.send(.close([workspace])) }
        region.onActivateWithModifiers = { [weak self, weak region] id, flags in
            // The profile control opens its menu over itself.
            if let view = region?.itemView(id), view.showsAvatar, self?.footerBand.showProfileMenu(from: view) == true { return }
            self?.model.send(.activateItem(id, opensWorkspace: flags.contains(.option)))
        }
        region.onToggleSection = { [weak self] id in self?.model.send(.toggleLayoutSection(id)) }
        // Edit mode's ✕: the menu's Remove (one undo step, the document's own op).
        region.onRemoveItem = { [weak self] id in self?.model.send(.layout(.itemRemove(id))) }
        region.isEditing = isEditingItems && region !== footerRegion
    }

    /// Gives the three regions their sections: the band above the list,
    /// the band below it without the footer section, and the footer section
    /// alone (when it is in the band below).
    /// `reloadsList` false: the caller reloads the list right after (one reload for the rows and the blocks).
    func updateBands(reloadsList: Bool = true) {
        let width = bounds.width
        var hidden = Set(model.resolvedItemInfo.filter(\.value.isHidden).keys)
        // `sidebar.showProfileControl` off (cx-wab7m): the profile button draws in no band.
        if !design.sidebarSections.showProfileControl {
            for section in model.layout.sections { hidden.formUnion(section.items.filter { $0.ref == .builtIn(.account) }.map(\.id)) }
        }
        let (above, below) = model.layout.bands(room: model.activeProfileID?.rawValue)
        let apps = model.suppressedApps
        let shownAbove = model.placingTransientItems(in: above.presenting(hidingItems: hidden, apps: apps))
        let shownBelow = below.presenting(hidingItems: hidden, apps: apps)
        let isFooter = { (section: LayoutSection) in section.id == SidebarLayoutDocument.bottomSectionID }
        let look = SidebarSectionTunables.currentLook
        // The footer keeps the full row (its avatar and search); the bands' rows follow Minimal Mode like the list's.
        let footerBase = SidebarRegionMetrics.standard
        // The bands' rows end where the list's do, `rowEdgeGap` from the sidebar's edge (Leo 2026-10-27); the footer keeps its own.
        var metrics = SidebarRegionMetrics.standard(minimal: design.sidebarSections.minimal)
        metrics.trailingTrim = SidebarStyle.rowTrailingTrim
        // The selection is not content: `showActiveTopItem` marks its item active (its glyph, accessibility).
        var selectedInfos = model.resolvedItemInfo
        for transient in model.transientTopItems { selectedInfos[transient.item.id] = transient.info }
        func content(_ sections: [LayoutSection], metrics shown: SidebarRegionMetrics? = nil) -> SidebarRegionView.Content {
            SidebarRegionView.Content(sections: sections.map(titled), infos: selectedInfos, collapsed: model.collapsedLayoutSections,
                                      look: look, metrics: shown ?? metrics, drawsLines: Borders.drawsLines, appHeights: appHeights(sections, width: width),
                                      fontSize: SidebarStyle.titleFont.pointSize)
        }
        if model.docDrag != nil {
            // The sidebar document (one renderer): its sections draw in the list, in document order; the band
            // above keeps only the client's items with nothing to follow. One anchored after an item the
            // document shows (Channels after Home) draws right after it in its block.
            let docSections = model.placingTransientItems(in: above.presenting(hidingItems: hidden, apps: apps), anchoredOnly: true).map(titled)
            // Only the blocks' own items' infos: another item's change does not reload the list.
            let shownIDs = Set(docSections.flatMap(\.items).map(\.id))
            // A block's rows end where the list's other rows do, `rowEdgeGap` from the edge (`rowTrailingTrim`): a
            // row's pill is inset `horizontalInset` in its frame, as the region metrics' inset is.
            var listMetrics = metrics
            listMetrics.trailingTrim = SidebarStyle.rowTrailingTrim
            let blocks = SidebarListBlocks(sections: Dictionary(docSections.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first }),
                                           infos: selectedInfos.filter { shownIDs.contains($0.key) }, collapsed: model.collapsedLayoutSections, look: look,
                                           metrics: listMetrics,
                                           drawsLines: Borders.drawsLines, appHeights: appHeights(docSections, width: width))
            let loose = model.placingTransientItems(in: []).map { section in
                var section = section
                section.items.removeAll { shownIDs.contains($0.id) }
                return section
            }
            aboveRegion.update(content(loose.filter { !$0.items.isEmpty }), width: width)
            if list.blocks != blocks {
                list.blocks = blocks
                // The document changed under the list (an item added, a section an agent filled): calm, not under the pointer.
                if reloadsList { list.showModelChange(animates: true) }
            }
        } else {
            aboveRegion.update(content(shownAbove), width: width)
            if list.blocks != nil {
                list.blocks = nil
                list.reload(animated: false)
            }
        }
        // No bottom-left sections (Lawrence 2026-10-10, cx-n0i9: "no more bottom left stuff"): the
        // band below the list draws nothing; only the footer row stays. A stored layout keeps
        // its sections there (no user data is removed); they just do not draw.
        belowRegion.update(content([]), width: width)
        let footer = shownBelow.filter(isFooter)
        // The footer line ends on the bottom margin, not on the section's padding over it.
        var footerMetrics = footerBase
        footerMetrics.bottomPadding = footerBand.footerBottomPadding(rowHeight: footerBase.rowHeight)
        footerRegion.update(content(footer, metrics: footerMetrics), width: width)
        releaseAppSections(shown: shownAbove + footer)
    }

    /// Draws the one selection on the top item it names, in every band and list block: the old and new
    /// item repaint, nothing lays out (a workspace switch to a workspace with a tile, I6).
    func showActiveTopItem() {
        let active: LayoutItemID? = if case let .topItem(id)? = model.selectedItem { id } else { nil }
        for region in [aboveRegion, belowRegion, footerRegion] { region.activeItem = active }
        list.activeTopItem = active
    }

    /// App sections no band shows any more release their content; one that
    /// moved between bands is still shown and keeps it.
    private func releaseAppSections(shown: [LayoutSection]) {
        let live = Set(shown.filter { $0.content == .app }.compactMap(\.contribution))
        for gone in shownAppContributions.subtracting(live) { appSections?.release(gone) }
        shownAppContributions = live
    }

    /// Lays out the bands between `top` and the bottom: the pinned footer
    /// section at the bottom, `footerHeight` (dots, cards) above the band
    /// below the list; returns the list's frame between the bands. Call
    /// `updateBands()` first.
    func layoutBands(top y: CGFloat, footerHeight: CGFloat) -> NSRect {
        let b = bounds
        // The footer section takes its full height, never capped or scrolled, over the bottom margin.
        let pinned = footerRegion.layoutResult.height, inset = SidebarStyle.bottomInset
        footerRegion.frame = NSRect(x: 0, y: b.height - inset - pinned, width: b.width, height: pinned)
        // Pinned item sections above and below the list, each capped at
        // its share of the height (then it scrolls inside).
        let available = max(0, b.height - y - footerHeight - pinned - inset)
        let look = SidebarSectionTunables.currentLook
        let (aboveHeight, belowHeight) = SidebarBandHeights.resolve(
            above: aboveRegion.layoutResult, below: belowRegion.layoutResult, available: available,
            preferences: SidebarAppHeights.preferences(below: belowRegion), minimumList: SidebarDensityTokens.rowHeight * 3,
            bandFloor: SidebarDensityTokens.rowHeight + Metrics.space2)
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
            heights[section.id] = SidebarAppHeights.height(provider, contribution, width: width, sidebarHeight: bounds.height)
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
        // Inset like the rows' pills (one gutter, Leo 2026-10-13), so its ends line up with theirs.
        let inset = list.inset
        aboveLine.frame = NSRect(x: inset, y: aboveY - width, width: max(0, bounds.width - inset * 2), height: width)
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
