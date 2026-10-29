import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-28, on the top of the sidebar: "the alignment"; on its glyphs: "i feel like this is misaligned
/// checkmark :( can we all audit the checkmarks and whatnot"; on the trailing marks: "eg look at this alignment :("
/// (two blue unread dots right of two red (i) marks). Every leading glyph (a band row's, a pinned row's pin, a
/// workspace row's icon) centers on one icon column and on its title's center line, and every trailing mark (the
/// unread dot, an error, Home's dot) centers on one trailing column.
@MainActor @Suite(.serialized) struct SidebarIconColumnTests {
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

    /// The center of what `view`'s layer tree actually paints (pixels with alpha over a quarter), in the list: a
    /// glyph whose ink sits off its box's center reads off the column however its box is placed. Nil when nothing paints.
    static func inkCenter(_ list: SidebarListView, _ view: NSView) -> CGPoint? {
        guard let layer = view.layer, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let scale: CGFloat = 4
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Layer space is y-down for a flipped view: draw it so row 0 of the buffer is the view's minY.
        ctx.scaleBy(x: scale, y: scale)
        if !view.isFlipped { ctx.translateBy(x: 0, y: view.bounds.height); ctx.scaleBy(x: 1, y: -1) }
        layer.render(in: ctx)
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var (minX, minY, maxX, maxY) = (Int.max, Int.max, Int.min, Int.min)
        for y in 0..<h { for x in 0..<w where data[(y * w + x) * 4 + 3] > 64 {
            (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
        } }
        guard minX <= maxX else { return nil }
        // CGContext rows run bottom-up in memory for a bitmap context: row index y is the view's y from the top.
        let cx = CGFloat(minX + maxX + 1) / 2 / scale, cyTop = CGFloat(minY + maxY + 1) / 2 / scale
        let local = CGPoint(x: cx, y: view.isFlipped ? cyTop : view.bounds.height - cyTop)
        return list.convert(local, from: view)
    }

    /// Home's glyph, the pin and a workspace row's icon share one center x.
    @Test(arguments: HomePinnedRowAlignmentTests.cases)
    func leadingGlyphsShareOneCenterX(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, c.minimal) {
            let (list, window) = Self.list(width: c.width)
            defer { window.close() }
            let home = try HomePinnedRowAlignmentTests.item(list, Self.home.id)
            let pin = try HomePinnedRowAlignmentTests.item(list, Self.pinned.id)
            let iconRow = try HomePinnedRowAlignmentTests.row(list, Self.icon)
            let homeX = Self.center(list, try #require(home.glyphInkFrame, "Home drew no glyph"), in: home).x
            let pinX = Self.center(list, try #require(pin.pinInkFrame, "the pinned row drew no pin"), in: pin).x
            let iconX = Self.center(list, iconRow.icon.frame, in: iconRow).x
            #expect(abs(homeX - iconX) <= Self.tolerance, "\(c.testDescription): Home's glyph centers at \(homeX), a row icon at \(iconX)")
            #expect(abs(pinX - iconX) <= Self.tolerance, "\(c.testDescription): the pin centers at \(pinX), a row icon at \(iconX)")
        }
    }

    /// Each leading glyph sits on its own title's center line.
    @Test(arguments: HomePinnedRowAlignmentTests.cases)
    func leadingGlyphsSitOnTheirTitlesCenterLine(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, c.minimal) {
            let (list, window) = Self.list(width: c.width)
            defer { window.close() }
            let home = try HomePinnedRowAlignmentTests.item(list, Self.home.id)
            let pin = try HomePinnedRowAlignmentTests.item(list, Self.pinned.id)
            let iconRow = try HomePinnedRowAlignmentTests.row(list, Self.icon)
            let pairs: [(String, CGFloat, CGFloat)] = [
                ("Home", Self.center(list, try #require(home.glyphInkFrame), in: home).y, Self.center(list, home.titleFrame, in: home).y),
                ("pin", Self.center(list, try #require(pin.pinInkFrame), in: pin).y, Self.center(list, pin.titleFrame, in: pin).y),
                ("icon", Self.center(list, iconRow.icon.frame, in: iconRow).y, Self.center(list, iconRow.title.frame, in: iconRow).y),
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
            // What a person sees: the drawn ink of each mark, not only its box.
            let inks = try [("unread", unreadRow.rowBadge), ("error", errorRow.rowBadge), ("Home", home.rowBadge)].map { name, badge in
                (name, try #require(Self.inkCenter(list, badge), "the \(name) mark painted nothing"))
            }
            print("ICONCOL|\(c.testDescription)|" + inks.map { "\($0.0)=\($0.1.x),\($0.1.y)" }.joined(separator: "|"))
            for (name, ink) in inks.dropFirst() {
                #expect(abs(ink.x - inks[0].1.x) <= Self.tolerance,
                        "\(c.testDescription): the \(name) mark's ink centers at \(ink.x), the unread dot's at \(inks[0].1.x)")
            }
            let rows: [(String, CGPoint, NSView)] = [("unread", dot, unreadRow), ("error", error, errorRow), ("Home", homeDot, home)]
            for (name, mark, row) in rows {
                let rowMidY = Self.center(list, row.bounds, in: row).y
                #expect(abs(mark.y - rowMidY) <= Self.tolerance, "\(c.testDescription): the \(name) mark centers at y \(mark.y), its row at \(rowMidY)")
            }
        }
    }
}
