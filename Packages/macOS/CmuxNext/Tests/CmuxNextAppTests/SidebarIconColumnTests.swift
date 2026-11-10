import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-10-28, on the top of the sidebar: "the alignment"; on its glyphs: "i feel like this is misaligned
/// checkmark :( can we all audit the checkmarks and whatnot"; on the trailing marks: "eg look at this alignment :("
/// (two blue unread dots right of two red (i) marks). Every leading glyph (a band row's, a pinned row's pin, a
/// workspace row's icon) starts on one icon column's leading edge and centers on its title's center line, and every trailing mark (the
/// unread dot, an error, Home's dot) centers on one trailing column.
@MainActor @Suite(.closesItsWindows, .serialized) struct SidebarIconColumnTests {
    typealias Case = HomePinnedRowAlignmentTests.Case

    static let home = LayoutItem(id: LayoutItemID("itm_column_home"), ref: .builtIn(.home))
    static let pinned = LayoutItem(id: LayoutItemID("itm_column_pin"), ref: .workspace("local:ws-column-pin"))
    static let icon = WorkspaceID("ws-column-icon"), unread = WorkspaceID("ws-column-unread"), failed = WorkspaceID("ws-column-error")
    static let tolerance = HomePinnedRowAlignmentTests.tolerance

    /// Home (with its unread dot), one pinned workspace, then a workspace with an icon, an unread one and a failed one.
    static func list(width: CGFloat) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [home])
        let pins = SidebarLayoutDocument.pinnedSection(items: [pinned])
        var homeInfo = SidebarItemInfo.fallback(for: home)
        homeInfo.unreadDot = true
        var pinInfo = SidebarItemInfo(title: "Cloud Chief rebuild", symbol: "textformat")
        pinInfo.textOnly = true
        pinInfo.workspace = WorkspaceID("ws-column-pin")
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
            SidebarSection(kind: .custom(SidebarCustomSection(id: pins.id.rawValue)), nodes: []),
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(SidebarWorkspace(id: icon, title: "Ship it", icon: .emoji("🚀"))),
                .workspace(SidebarWorkspace(id: unread, title: "Unread work", unread: .dot)),
                .workspace(SidebarWorkspace(id: failed, title: "Failed run", activity: .error)),
            ]),
        ])
        let list = SidebarListView(model: model)
        var metrics = SidebarRegionMetrics.standard
        metrics.trailingTrim = SidebarStyle.rowTrailingTrim
        list.blocks = SidebarListBlocks(sections: [top.id.rawValue: top, pins.id.rawValue: pins],
                                        infos: [home.id: homeInfo, pinned.id: pinInfo], collapsed: [],
                                        look: .quiet, metrics: metrics, drawsLines: false, appHeights: [:])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        for region in list.blockRegions { region.itemViews.values.forEach { $0.layoutSubtreeIfNeeded(); $0.layout() } }
        return (list, window)
    }

    static func center(_ list: SidebarListView, _ rect: CGRect, in view: NSView) -> CGPoint {
        let r = list.convert(rect, from: view)
        return CGPoint(x: r.midX, y: r.midY)
    }

    /// The row badge's one glyph center, in the list.
    static func markCenter(_ list: SidebarListView, _ badge: RowBadgeView) throws -> CGPoint {
        try #require(!badge.isHidden, "the row drew no trailing mark")
        return center(list, try #require(badge.glyphFrames.first), in: badge)
    }

    /// The center of the opaque pixels in a status mark's `pixels`-square mask, from the mask's center, in pixels.
    static func artOffset(_ mark: StatusMark, pixels: Int) throws -> CGPoint {
        let mask = try #require(StatusMarkArt.mask(mark, pixels: pixels), "\(mark) drew no mask")
        let data = try #require(mask.dataProvider?.data as Data?)
        var (minX, minY, maxX, maxY) = (Int.max, Int.max, Int.min, Int.min)
        for y in 0..<mask.height { for x in 0..<mask.width where data[y * mask.bytesPerRow + x] > 64 {
            (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
        } }
        try #require(minX <= maxX, "\(mark) painted nothing")
        let half = CGFloat(pixels) / 2
        return CGPoint(x: CGFloat(minX + maxX + 1) / 2 - half, y: CGFloat(minY + maxY + 1) / 2 - half)
    }

    /// Home's glyph and the pin start their ink on one x, the icon column's leading edge, where a workspace row's icon
    /// column starts too (https://github.com/manaflow-ai/cmux/issues/38061 lined them up by center; Lawrence 2026-11-09,
    /// "home/pin icons not left aligned with 'Fix…'", by their left edge, the titles' edge).
    @Test(arguments: HomePinnedRowAlignmentTests.cases)
    func leadingGlyphsStartOnOneX(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, c.minimal) {
            let (list, window) = Self.list(width: c.width)
            defer { window.close() }
            let home = try HomePinnedRowAlignmentTests.item(list, Self.home.id)
            let pin = try HomePinnedRowAlignmentTests.item(list, Self.pinned.id)
            let iconRow = try HomePinnedRowAlignmentTests.row(list, Self.icon)
            let homeX = list.convert(try #require(home.glyphInkFrame, "Home drew no glyph"), from: home).minX
            let pinX = list.convert(try #require(pin.pinInkFrame, "the pinned row drew no pin"), from: pin).minX
            let columnX = list.convert(home.leadingColumnFrame, from: home).minX
            let iconColumnX = list.convert(iconRow.icon.frame, from: iconRow).minX
            #expect(abs(homeX - columnX) <= Self.tolerance, "\(c.testDescription): Home's glyph starts at \(homeX), its column at \(columnX)")
            #expect(abs(pinX - columnX) <= Self.tolerance, "\(c.testDescription): the pin starts at \(pinX), the column at \(columnX)")
            #expect(abs(iconColumnX - columnX) <= Self.tolerance, "\(c.testDescription): a row icon's column at \(iconColumnX), Home's at \(columnX)")
        }
    }

    /// The center line of a title's capitals in the list: the label's baseline less half its cap height, from the
    /// label's own frame and font, independent of the rows' placement helpers. A title's frame is taller than its
    /// capitals by the font's ascender and descender, so its frame's middle is off that line by an amount that
    /// changes with the face (the system font replaced Inter in ab5bc5a1).
    static func capitalsMidY(_ list: SidebarListView, frame: CGRect, baseline: CGFloat, capHeight: CGFloat, in row: NSView) -> CGFloat {
        // The rows are flipped: the baseline is `baseline` below the label's top.
        list.convert(CGPoint(x: frame.midX, y: frame.minY + baseline - capHeight / 2), from: row).y
    }

    /// The capitals' center line of a band or pinned row's title, in the list.
    static func capitalsMidY(_ list: SidebarListView, of item: SidebarItemRowView) throws -> CGFloat {
        let font = try #require(item.title.font)
        return capitalsMidY(list, frame: item.title.frame, baseline: item.title.firstBaselineOffsetFromTop, capHeight: font.capHeight, in: item)
    }

    /// Each leading glyph sits on its own title's center line: the line through the middle of its capitals, where
    /// a row centers its title (#27598).
    @Test(arguments: HomePinnedRowAlignmentTests.cases)
    func leadingGlyphsSitOnTheirTitlesCenterLine(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, c.minimal) {
            let (list, window) = Self.list(width: c.width)
            defer { window.close() }
            let home = try HomePinnedRowAlignmentTests.item(list, Self.home.id)
            let pin = try HomePinnedRowAlignmentTests.item(list, Self.pinned.id)
            let iconRow = try HomePinnedRowAlignmentTests.row(list, Self.icon)
            // A marquee title draws its one line from its top, so its baseline is the font's ascender below it.
            let iconTitle = Self.capitalsMidY(list, frame: iconRow.title.frame, baseline: iconRow.title.font.ascender,
                                              capHeight: iconRow.title.font.capHeight, in: iconRow)
            let pairs: [(String, CGFloat, CGFloat)] = [
                ("Home", Self.center(list, try #require(home.glyphInkFrame), in: home).y, try Self.capitalsMidY(list, of: home)),
                ("pin", Self.center(list, try #require(pin.pinInkFrame), in: pin).y, try Self.capitalsMidY(list, of: pin)),
                ("icon", Self.center(list, iconRow.icon.frame, in: iconRow).y, iconTitle),
            ]
            for (name, glyph, text) in pairs {
                #expect(abs(glyph - text) <= Self.tolerance, "\(c.testDescription): \(name) glyph centers at y \(glyph), its title at \(text)")
            }
        }
    }

    /// The unread dot, an error mark and Home's dot share one trailing center x, each on its row's center line.
    @Test(arguments: HomePinnedRowAlignmentTests.cases)
    func trailingMarksShareOneCenterX(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, c.minimal) {
            let (list, window) = Self.list(width: c.width)
            defer { window.close() }
            let home = try HomePinnedRowAlignmentTests.item(list, Self.home.id)
            let unreadRow = try HomePinnedRowAlignmentTests.row(list, Self.unread)
            let errorRow = try HomePinnedRowAlignmentTests.row(list, Self.failed)
            let dot = try Self.markCenter(list, unreadRow.rowBadge), error = try Self.markCenter(list, errorRow.rowBadge)
            let homeDot = try Self.markCenter(list, home.rowBadge)
            #expect(abs(dot.x - error.x) <= Self.tolerance, "\(c.testDescription): the unread dot centers at \(dot.x), the error at \(error.x)")
            #expect(abs(homeDot.x - error.x) <= Self.tolerance, "\(c.testDescription): Home's dot centers at \(homeDot.x), the error at \(error.x)")
            let rows: [(String, CGPoint, NSView)] = [("unread", dot, unreadRow), ("error", error, errorRow), ("Home", homeDot, home)]
            for (name, mark, row) in rows {
                let rowMidY = Self.center(list, row.bounds, in: row).y
                #expect(abs(mark.y - rowMidY) <= Self.tolerance, "\(c.testDescription): the \(name) mark centers at y \(mark.y), its row at \(rowMidY)")
            }
        }
    }

    /// What a person sees inside the shared box: each trailing mark's art (the unread dot, the error (i), done, the
    /// waiting dot, the static glyphs) centers in its square at 1x, 2x and 3x, so marks whose boxes share the column
    /// also share it in ink.
    @Test(arguments: [10, 20, 30])
    func trailingMarkArtCentersInItsBox(_ pixels: Int) throws {
        let glyphs: [StaticStatusGlyph] = [.dot, .info, .error, .done]
        for glyph in glyphs {
            let offset = try Self.artOffset(.vector(glyph), pixels: pixels)
            #expect(abs(offset.x) <= 0.5 && abs(offset.y) <= 0.5, "\(glyph) at \(pixels) px draws \(offset) px off its box's center")
        }
    }

    /// A band section header's chevron centers on its rows' trailing column in every look: a card keeps its rows at the
    /// header's width (no `trailingTrim`), the other looks run the rows `trailingTrim` past it (review of #27292: the
    /// chevron sat 4.5 pt right of a card's marks when the header always took the trim).
    @Test(arguments: SectionsLookVariant.allCases)
    func aBandHeadersChevronCentersOnItsRowsColumn(_ look: SectionsLookVariant) throws {
        let item = LayoutItem(id: LayoutItemID("itm_column_band"), ref: .builtIn(.home))
        let section = LayoutSection(id: LayoutSectionID("sec_column_band"), title: "Band", region: .top, items: [item])
        var metrics = SidebarRegionMetrics.standard
        metrics.trailingTrim = SidebarStyle.rowTrailingTrim
        let layout = SidebarRegionLayout.make(sections: [section], width: 260, look: look, collapsed: [], metrics: metrics)
        guard let headerRow = layout.rows.first(where: { if case .header = $0.kind { true } else { false } }) else { return }
        let itemRow = try #require(layout.rows.first { if case .item = $0.kind { true } else { false } }, "\(look): no item row")
        let header = SidebarSectionHeaderView(frame: headerRow.frame)
        header.configure(title: "Band", collapsed: false)
        header.trailingTrim = SidebarRegionLayout.itemTrailingTrim(section, look: look, metrics: metrics)
        header.layoutSubtreeIfNeeded()
        header.layout()
        let chevronX = headerRow.frame.minX + header.chevron.frame.midX
        // A band row's fill is inset by `horizontalInset` in its frame (`SidebarItemRowView.layoutColumnMark`).
        let rowColumn = itemRow.frame.minX + SidebarStyle.trailingColumnCenterX(rowWidth: itemRow.frame.width - SidebarStyle.horizontalInset)
        #expect(abs(chevronX - rowColumn) <= Self.tolerance, "\(look): the header chevron centers at \(chevronX), its rows' marks at \(rowColumn)")
    }

    /// Pinned-section titles use the same optical midline as machine headers and row glyphs, at every text size.
    /// Measure the real label's baseline and cap height, independently of the production positioning helper.
    @Test(arguments: SidebarDensity.allCases, SidebarTextSize.allCases)
    func aBandHeaderTitleAndChevronShareTheMidLine(density: SidebarDensity, textSize: SidebarTextSize) throws {
        try SidebarGroupRailAlignmentTests.with(density, .off, textSize: textSize) {
            let header = SidebarSectionHeaderView(frame: NSRect(x: 0, y: 0, width: 260, height: SidebarDensityTokens.headerHeight))
            header.configure(title: "Projects", collapsed: true)
            header.layout()
            let label = try #require(header.subviews.compactMap { $0 as? ChromeLabel }.first)
            let font = try #require(label.font)
            let inkMidY = label.frame.minY + label.firstBaselineOffsetFromTop - font.capHeight / 2
            #expect(abs(inkMidY - header.bounds.midY) <= Self.tolerance,
                    "\(density)/\(textSize): title optical center \(inkMidY), row center \(header.bounds.midY)")
            #expect(abs(header.chevron.frame.midY - inkMidY) <= Self.tolerance,
                    "\(density)/\(textSize): title and chevron must share a midline")
        }
    }
}
