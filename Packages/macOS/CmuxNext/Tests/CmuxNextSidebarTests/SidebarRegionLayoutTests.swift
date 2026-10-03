import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// Sticky section bands (plans/cmux-next/sidebar-sections.md 1, 7): the
/// band split around the workspace list, each look's frames, caps, the
/// sidebar view's placement, and the model's section intents.
@MainActor @Suite struct SidebarRegionLayoutTests {
    private let m = SidebarRegionMetrics(rowHeight: 28, headerHeight: 22, inset: 8, sectionGap: 8, padding: 4,
                                         cardPadding: 4, tileMinWidth: 42, tileHeight: 36, tileGap: 8)
    private let defaults = SidebarLayoutDocument.defaults

    private func section(_ id: String, title: String? = nil, region: SidebarRegion = .top, look: SectionLook = .builtIn,
                         maxRows: Int? = nil, room: String? = nil, items count: Int) -> LayoutSection {
        LayoutSection(id: LayoutSectionID(id), title: title, region: region, look: look, room: room, maxRows: maxRows,
                      items: (0..<count).map { LayoutItem(id: LayoutItemID("\(id)_\($0)"), ref: .url("u\(id)\($0)")) })
    }

    // MARK: Bands

    @Test func defaultBandsAreHomeAboveSettingsCustomizeAndAccountBelow() {
        let bands = defaults.bands(room: nil)
        #expect(bands.above.flatMap(\.items).map(\.ref) == [.builtIn(.home), .builtIn(.appStore)])
        #expect(bands.below.flatMap(\.items).map(\.ref) == [.builtIn(.settings), .builtIn(.customize), .builtIn(.account)])
    }

    @Test func bandsSplitAtTheWorkspacesSectionWhereverItIs() throws {
        let moved = try SidebarLayoutReducer.reduce(defaults, .sectionMove(SidebarLayoutDocument.workspacesSectionID, region: .bottom, index: 1)).get()
        let bands = moved.bands(room: nil)
        #expect(bands.above.map(\.id) == [SidebarLayoutDocument.topSectionID, SidebarLayoutDocument.bottomSectionID])
        #expect(bands.below.isEmpty)
    }

    @Test func roomScopedSectionsJoinTheBandOnlyInTheirRoom() {
        var doc = defaults
        doc.sections.insert(section("p", title: "Project", room: "prof_a", items: 2), at: 1)
        #expect(doc.bands(room: "prof_a").above.count == 2)
        #expect(doc.bands(room: "prof_b").above.count == 1)
    }

    // MARK: Looks

    @Test func quietRowsStackUnderAHeader() {
        let layout = SidebarRegionLayout.make(sections: [section("a", title: "A", items: 2)], width: 240, look: .quiet, collapsed: [], metrics: m)
        #expect(layout.rows.map(\.frame.minY) == [4, 26, 54])
        #expect(layout.height == CGFloat(86))
        #expect(layout.cards.isEmpty)
        #expect(layout.rows.allSatisfy { $0.frame.width == 240 })
    }

    @Test func untitledEmptySectionsTakeNoSpace() {
        let layout = SidebarRegionLayout.make(sections: [section("a", items: 0)], width: 240, look: .quiet, collapsed: [], metrics: m)
        #expect(layout == .empty)
    }

    @Test func collapsedSectionsKeepOnlyTheirHeader() {
        let layout = SidebarRegionLayout.make(sections: [section("a", title: "A", items: 3)], width: 240, look: .quiet,
                                              collapsed: [LayoutSectionID("a")], metrics: m)
        #expect(layout.rows.count == 1)
        #expect(layout.height == CGFloat(30))
        // An untitled section cannot collapse.
        let untitled = SidebarRegionLayout.make(sections: [section("b", items: 3)], width: 240, look: .quiet,
                                                collapsed: [LayoutSectionID("b")], metrics: m)
        #expect(untitled.rows.count == 3)
    }

    @Test func cardsInsetEachSection() {
        let layout = SidebarRegionLayout.make(sections: [section("a", items: 1), section("b", items: 2)], width: 240, look: .card,
                                              collapsed: [], metrics: m)
        #expect(layout.cards.count == 2)
        #expect(layout.cards[0] == CGRect(x: 8, y: 4, width: 224, height: 4 + 28 + 4))
        #expect(layout.cards[1].minY == layout.cards[0].maxY + 8)
        #expect(layout.rows.allSatisfy { $0.frame.minX == 8 && $0.frame.width == 224 })
    }

    @Test func trayTilesBuiltInSectionsInAGrid() {
        let layout = SidebarRegionLayout.make(sections: [section("a", items: 6)], width: 240, look: .tray, collapsed: [], metrics: m)
        let tiles = layout.rows.filter { if case .tile = $0.kind { true } else { false } }
        #expect(tiles.count == 6)
        // 224 points fit 4 columns of at least 42 with 8 gaps.
        #expect(Set(tiles.map(\.frame.minY)).count == 2)
        #expect(tiles[0].frame.width == CGFloat(50))
    }

    @Test func trayKeepsListLookSectionsAsRows() {
        let layout = SidebarRegionLayout.make(sections: [section("a", look: .list, items: 2)], width: 240, look: .tray, collapsed: [], metrics: m)
        #expect(layout.rows.allSatisfy { if case .item = $0.kind { true } else { false } })
    }

    @Test func linesLooksDrawNoHeadersAndALineBetweenSections() {
        let sections = [section("a", title: "A", items: 1), section("b", title: "B", items: 2)]
        for look in [SectionsLookVariant.lines, .linesIcons] {
            let layout = SidebarRegionLayout.make(sections: sections, width: 240, look: look, collapsed: [], metrics: m)
            #expect(!layout.rows.contains { if case .header = $0.kind { true } else { false } })
            #expect(layout.separators.count == 1)
            #expect(layout.separators[0].width == 240 && layout.separators[0].height == 1)
            #expect(layout.sectionFrames.count == 2)
            #expect(layout.separators[0].minY > layout.sectionFrames[0].maxY && layout.separators[0].maxY < layout.sectionFrames[1].minY)
        }
        // Quiet keeps headers and no section lines.
        let quiet = SidebarRegionLayout.make(sections: sections, width: 240, look: .quiet, collapsed: [], metrics: m)
        #expect(quiet.separators.isEmpty)
    }

    @Test func linesIconsShowsBuiltInSectionsAsFixedIconButtons() {
        let layout = SidebarRegionLayout.make(sections: [section("a", items: 3), section("b", look: .list, items: 1)], width: 240,
                                              look: .linesIcons, collapsed: [], metrics: m)
        let tiles = layout.rows.filter { if case .tile = $0.kind { true } else { false } }
        #expect(tiles.count == 3)
        #expect(tiles.allSatisfy { $0.frame.width == 28 && $0.frame.height == 28 })
        #expect(Set(tiles.map(\.frame.minY)).count == 1)
        #expect(layout.rows.contains { if case .item = $0.kind { true } else { false } })
    }

    @Test func hiddenTitlesDrawNoHeaderAndCannotCollapse() {
        var hidden = section("a", title: "A", items: 2)
        hidden.showsTitle = false
        let layout = SidebarRegionLayout.make(sections: [hidden], width: 240, look: .quiet, collapsed: [hidden.id], metrics: m)
        #expect(layout.rows.count == 2)
    }

    // MARK: Caps

    @Test func maxRowsCapsTheStickyHeight() {
        let layout = SidebarRegionLayout.make(sections: [section("a", maxRows: 2, items: 10)], width: 240, look: .quiet, collapsed: [], metrics: m)
        #expect(layout.height == CGFloat(288))
        #expect(layout.cappedHeight == CGFloat(64))
        #expect(layout.stickyHeight(available: 1_000, share: 0.5) == 64)
    }

    @Test func theShareCapsTheStickyHeight() {
        let layout = SidebarRegionLayout.make(sections: [section("a", items: 10)], width: 240, look: .quiet, collapsed: [], metrics: m)
        #expect(layout.stickyHeight(available: 600, share: 1.0 / 3.0) == 200)
        #expect(layout.stickyHeight(available: 6_000, share: 1.0 / 3.0) == layout.height)
    }

    // MARK: Model

    @Test func modelAppliesSectionIntentsLocally() {
        let model = SidebarModel()
        model.send(.layout(.itemRemove(LayoutItemID("itm_home"))))
        #expect(model.layout.firstItem(with: .builtIn(.home)) == nil)
        model.send(.toggleLayoutSection(SidebarLayoutDocument.bottomSectionID))
        #expect(model.collapsedLayoutSections == [SidebarLayoutDocument.bottomSectionID])
        model.send(.toggleLayoutSection(SidebarLayoutDocument.bottomSectionID))
        #expect(model.collapsedLayoutSections.isEmpty)
    }

    // MARK: View

    @Test func sidebarPlacesBandsAroundTheList() throws {
        let model = SidebarModel(sections: SidebarDemoMock.makeSections())
        let view = SidebarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        view.layoutSubtreeIfNeeded()
        let home = try #require(view.aboveRegion.itemView(LayoutItemID("itm_home")))
        #expect(home.info.title == SidebarBuiltIn.home.title)
        #expect(view.aboveRegion.layoutResult.height > 0)
        #expect(view.belowRegion.itemView(LayoutItemID("itm_settings")) != nil)
        let aboveTop = try #require(view.aboveRegion.enclosingScrollView?.superview).frame.minY
        let aboveBottom = try #require(view.aboveRegion.enclosingScrollView?.superview).frame.maxY
        let belowTop = try #require(view.belowRegion.enclosingScrollView?.superview).frame.minY
        let list = try #require(view.list.enclosingScrollView?.superview).frame
        #expect(list.minY == aboveBottom && list.maxY == belowTop)

        model.layout = try SidebarLayoutReducer.reduce(model.layout, .sectionRemove(SidebarLayoutDocument.topSectionID)).get()
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        #expect(view.aboveRegion.layoutResult == .empty)
        #expect(try #require(view.list.enclosingScrollView?.superview).frame.minY == aboveTop)
    }

    @Test func clickingAnItemSendsActivate() throws {
        let model = SidebarModel()
        var sent: [SidebarIntent] = []
        model.onIntent = { sent.append($0) }
        let view = SidebarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        view.layoutSubtreeIfNeeded()
        let settings = try #require(view.belowRegion.itemView(LayoutItemID("itm_settings")))
        #expect(settings.accessibilityPerformPress())
        #expect(sent == [.activateItem(LayoutItemID("itm_settings"))])
    }

    // MARK: Hidden apps (D55)

    @Test func hiddenItemsDrawNothingAndStayInTheLayout() throws {
        let model = SidebarModel()
        var doc = SidebarLayoutDocument.defaults
        doc.sections[0].items.append(LayoutItem(id: LayoutItemID("itm_app"), ref: .app("manaflow-ai/github-prs")))
        model.layout = doc
        model.itemInfo = [LayoutItemID("itm_app"): SidebarItemInfo(title: "PRs", symbol: "app", isHidden: true)]
        let view = SidebarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        view.layoutSubtreeIfNeeded()
        #expect(view.aboveRegion.itemView(LayoutItemID("itm_app")) == nil)
        #expect(view.aboveRegion.itemView(LayoutItemID("itm_home")) != nil)
        #expect(model.layout.item(LayoutItemID("itm_app")) != nil)
        model.itemInfo = [LayoutItemID("itm_app"): SidebarItemInfo(title: "PRs", symbol: "app")]
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        #expect(view.aboveRegion.itemView(LayoutItemID("itm_app")) != nil)
    }


    /// A suppressed app's sections and items draw nothing (no placeholder)
    /// and come back in their places when it is presented again.
    @Test func suppressedAppsDrawNothingAndReturnInPlace() {
        var doc = SidebarLayoutDocument.defaults
        doc.sections.insert(LayoutSection(id: LayoutSectionID("sec_app"), region: .top, content: .app, contribution: "a/prs#prs"), at: 1)
        doc.sections[0].items.insert(LayoutItem(id: LayoutItemID("itm_app"), ref: .app("a/prs")), at: 1)
        let hidden = doc.sections.presenting(hidingItems: [], apps: ["a/prs"])
        #expect(!hidden.contains { $0.id == LayoutSectionID("sec_app") })
        #expect(!hidden[0].items.contains { $0.id == LayoutItemID("itm_app") })
        let shown = doc.sections.presenting(hidingItems: [], apps: [])
        #expect(shown == doc.sections)
        #expect(shown[1].id == LayoutSectionID("sec_app") && shown[0].items[1].id == LayoutItemID("itm_app"))
    }

}
