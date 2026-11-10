import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// https://github.com/manaflow-ai/cmux/issues/38061, second pass. After https://github.com/manaflow-ai/cmux/pull/38089
/// centered the pin under Home's house, a tagged build still showed two defects (dark, 2x, measured from the window's
/// pixels): the pin drew in a 12 pt square, its ink 9 pt across under the house's 14.5, and a pinned workspace with its
/// own icon or color dot ("🚀 Rocket emoji", "● Red color") drew the pin, then the icon, then its title 29.5 pt right of
/// Home's label. Lawrence 2026-11-09 ("home/pin icons not left aligned with 'Fix…'"; "the workspace-row icons are
/// inconsistent") moved the shared line from the glyphs' centers to their left edge and sized each by its ink. The
/// contract: every pinned row's leading glyph (the pin, or the row's own icon or dot in the pin's place) starts its ink
/// on Home's glyph's left edge, the pin's ink is as large as the house's, and every pinned row's title starts at Home's
/// label x, at 1x and 2x, every density, Minimal Mode and text size.
@MainActor @Suite(.serialized, .closesItsWindows) struct PinnedRowsShareHomeColumnTests {
    nonisolated struct Case: CustomTestStringConvertible, Sendable {
        var density: SidebarDensity
        var minimal: SidebarMinimalMode
        var textSize: SidebarTextSize
        var scale: CGFloat
        var testDescription: String { "\(density.rawValue)/minimal-\(minimal.rawValue)/text-\(textSize.rawValue)/\(Int(scale))x" }
    }

    nonisolated static let cases: [Case] = [CGFloat(1), 2].flatMap { scale in
        SidebarTextSize.allCases.flatMap { textSize in
            SidebarDensity.allCases.flatMap { density in
                [SidebarMinimalMode.off, .both].map { Case(density: density, minimal: $0, textSize: textSize, scale: scale) }
            }
        }
    }

    /// A window on a display of `testScale` (the fleet's screens are all 2x), so the rows snap to its pixel grid.
    final class ScaledWindow: NSWindow {
        var testScale: CGFloat = 2
        override var backingScaleFactor: CGFloat { testScale }
    }

    static let home = LayoutItem(id: LayoutItemID("itm_share_home"), ref: .builtIn(.home))
    /// The pinned rows of the report: text only ("CLOUDMUX"), an emoji, a color dot, a favicon page.
    static let plain = LayoutItem(id: LayoutItemID("itm_share_plain"), ref: .workspace("local:ws-share-plain"))
    static let emoji = LayoutItem(id: LayoutItemID("itm_share_emoji"), ref: .workspace("local:ws-share-emoji"))
    static let dot = LayoutItem(id: LayoutItemID("itm_share_dot"), ref: .workspace("local:ws-share-dot"))
    static let page = LayoutItem(id: LayoutItemID("itm_share_page"), ref: .workspace("local:ws-share-page"))
    static var pins: [LayoutItem] { [plain, emoji, dot, page] }

    static func infos() -> [LayoutItemID: SidebarItemInfo] {
        func info(_ id: String, _ title: String, icon: WorkspaceIcon?, color: GroupColor? = nil) -> SidebarItemInfo {
            var info = SidebarItemInfo(workspaceRow: SidebarWorkspace(id: WorkspaceID(id), title: title, icon: icon), color: color)
            info.workspace = WorkspaceID(id)
            return info
        }
        return [
            home.id: .fallback(for: home),
            plain.id: info("ws-share-plain", "CLOUDMUX", icon: nil),
            emoji.id: info("ws-share-emoji", "Rocket emoji", icon: .emoji("🚀")),
            dot.id: info("ws-share-dot", "Red color", icon: .swatch(.red), color: .red),
            page.id: info("ws-share-page", "Docs page", icon: .favicon(PinnedSummaryDensityTests.favicon)),
        ]
    }

    /// The top block (Home) and the Pinned block, as the sidebar document draws them, in a window of `scale`.
    static func list(scale: CGFloat, width: CGFloat = 240) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [home])
        let pinned = SidebarLayoutDocument.pinnedSection(items: pins)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
            SidebarSection(kind: .custom(SidebarCustomSection(id: pinned.id.rawValue)), nodes: []),
        ])
        let list = SidebarListView(model: model)
        var metrics = SidebarRegionMetrics.standard
        metrics.trailingTrim = SidebarStyle.rowTrailingTrim
        list.blocks = SidebarListBlocks(sections: [top.id.rawValue: top, pinned.id.rawValue: pinned], infos: infos(), collapsed: [],
                                        look: .quiet, metrics: metrics, drawsLines: false, appHeights: [:])
        let window = ScaledWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 600), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
        window.testScale = scale
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        for region in list.blockRegions { region.itemViews.values.forEach { $0.needsLayout = true; $0.layoutSubtreeIfNeeded(); $0.layout() } }
        return (list, window)
    }

    /// Runs `body` with the sidebar at `c` and `sidebar.pinnedRowLeading` at its default.
    static func at(_ c: Case, _ body: () throws -> Void) throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.set(SidebarPinnedRowLeading.tunable.key, nil)
        try #require(SidebarPinnedRowLeading.tunable.value == .ownIcon, "the default look is ownIcon")
        try SidebarGroupRailAlignmentTests.with(c.density, c.minimal, textSize: c.textSize, body)
    }

    /// Every pinned row's leading glyph starts its ink on Home's glyph's left edge (one device pixel at 1x, where each
    /// snaps to a whole point; half a point at 2x).
    @Test(arguments: cases)
    func everyPinnedRowsLeadingGlyphStartsOnHomesEdge(_ c: Case) throws {
        try Self.at(c) {
            let (list, window) = Self.list(scale: c.scale)
            defer { window.close() }
            let home = try HomePinnedRowAlignmentTests.item(list, Self.home.id)
            let homeInk = list.convert(try #require(home.glyphInkFrame, "Home drew no glyph"), from: home)
            let tolerance = 1 / c.scale
            for item in Self.pins {
                let row = try HomePinnedRowAlignmentTests.item(list, item.id)
                let ink = list.convert(try #require(row.leadingInkFrame, "\(item.id.rawValue) draws nothing in the leading column"), from: row)
                #expect(abs(ink.minX - homeInk.minX) <= tolerance,
                        "\(c.testDescription): \(item.id.rawValue)'s leading glyph starts at \(ink.minX), Home's at \(homeInk.minX)")
            }
        }
    }

    /// The pin draws in Home's glyph square, so it reads as wide as the house beside it, not 4 pt smaller.
    @Test(arguments: cases)
    func thePinDrawsInHomesGlyphSquare(_ c: Case) throws {
        try Self.at(c) {
            let (list, window) = Self.list(scale: c.scale)
            defer { window.close() }
            let home = try HomePinnedRowAlignmentTests.item(list, Self.home.id)
            let plain = try HomePinnedRowAlignmentTests.item(list, Self.plain.id)
            let pin = try #require(plain.pinSquareFrame, "the text-only pinned row draws no pin")
            #expect(abs(pin.width - home.icon.frame.width) <= 0.01,
                    "\(c.testDescription): the pin's square is \(pin.width) pt, Home's glyph's \(home.icon.frame.width) pt")
        }
    }

    /// Every pinned row's title, with or without its own icon or dot, starts at Home's label x.
    @Test(arguments: cases)
    func everyPinnedTitleStartsAtHomesLabel(_ c: Case) throws {
        try Self.at(c) {
            let (list, window) = Self.list(scale: c.scale)
            defer { window.close() }
            let home = try HomePinnedRowAlignmentTests.item(list, Self.home.id)
            let homeX = list.convert(home.titleFrame, from: home).minX
            for item in Self.pins {
                let row = try HomePinnedRowAlignmentTests.item(list, item.id)
                let x = list.convert(row.titleFrame, from: row).minX
                #expect(abs(x - homeX) <= 0.5, "\(c.testDescription): \(item.id.rawValue)'s title starts at \(x), Home's label at \(homeX)")
            }
        }
    }

    /// A pinned group with its own icon draws it in the pin's place (`SidebarPinnedRowLeading`), so its name starts
    /// where a pinned group without one starts its name after the pin, and the icon centers where that pin does.
    @Test(arguments: cases)
    func pinnedGroupNamesStartAtOneXWithOrWithoutAnIcon(_ c: Case) throws {
        try Self.at(c) {
            _ = NSApplication.shared
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let plainID = GroupID("g-share-plain"), iconID = GroupID("g-share-icon")
            var withIcon = SidebarGroup(id: iconID, name: "Rocket group", color: .green, isPinned: true,
                                        workspaces: [SidebarWorkspace(id: WorkspaceID("w-share-a"), title: "a")])
            withIcon.icon = .emoji("🚀")
            let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [
                .group(SidebarGroup(id: plainID, name: "Plain group", color: .blue, isPinned: true,
                                    workspaces: [SidebarWorkspace(id: WorkspaceID("w-share-b"), title: "b")])),
                .group(withIcon),
            ])])
            let list = SidebarListView(model: model)
            let window = ScaledWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 600), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
            window.testScale = c.scale
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
            window.contentView = root
            list.frame = root.bounds
            root.addSubview(list)
            window.orderFrontRegardless()
            list.reload(animated: false)
            list.rowViews.values.forEach { $0.needsLayout = true; $0.layoutSubtreeIfNeeded() }
            let plain = try #require(list.rowViews[.group(plainID)] as? GroupHeaderRowView, "no plain pinned group header")
            let icon = try #require(list.rowViews[.group(iconID)] as? GroupHeaderRowView, "no pinned group header with an icon")
            let plainName = list.convert(plain.name.frame, from: plain).minX, iconName = list.convert(icon.name.frame, from: icon).minX
            #expect(abs(plainName - iconName) <= 0.5,
                    "\(c.testDescription): the pinned group's name starts at \(iconName) with an icon, \(plainName) without one")
            let pin = list.convert(try #require(plain.pinInkFrame, "the iconless pinned group draws no pin"), from: plain)
            #expect(icon.pinSquareFrame == nil, "\(c.testDescription): the pinned group with an icon still draws its pin")
            let glyph = list.convert(icon.glyph.frame, from: icon)
            #expect(abs(glyph.midX - pin.midX) <= 1 / c.scale + 0.5,
                    "\(c.testDescription): the group's icon centers at \(glyph.midX), the pin's ink at \(pin.midX)")
        }
    }

    /// The `pinThenIcon` look (Debug `sidebar.pinnedRowLeading`) keeps the pin first on every pinned row, its ink on
    /// Home's glyph's left edge, with the row's own icon after it.
    @Test func thePinThenIconLookKeepsThePinOnEveryRow() throws {
        try Self.at(Case(density: .compact, minimal: .off, textSize: .standard, scale: 2)) {
            let key = SidebarPinnedRowLeading.tunable.key
            defer { TunableStore.shared.set(key, nil) }
            try #require(TunableStore.shared.set(key, SidebarPinnedRowLeading.pinThenIcon.tunableValue) == SidebarPinnedRowLeading.pinThenIcon.tunableValue)
            let (list, window) = Self.list(scale: 2)
            defer { window.close() }
            let home = try HomePinnedRowAlignmentTests.item(list, Self.home.id)
            let homeInk = list.convert(try #require(home.glyphInkFrame), from: home)
            for item in Self.pins {
                let row = try HomePinnedRowAlignmentTests.item(list, item.id)
                let pin = list.convert(try #require(row.pinInkFrame, "\(item.id.rawValue) draws no pin"), from: row)
                #expect(abs(pin.minX - homeInk.minX) <= 0.5, "\(item.id.rawValue)'s pin starts at \(pin.minX), Home's glyph at \(homeInk.minX)")
            }
        }
    }
}
