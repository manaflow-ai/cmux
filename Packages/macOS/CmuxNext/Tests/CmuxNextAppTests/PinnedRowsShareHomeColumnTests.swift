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
/// inconsistent") moved the shared line from the glyphs' centers to their left edge and sized each by its ink.
///
/// https://github.com/manaflow-ai/cmux/issues/42431: the narrow pin hugged the column's left edge, 3 pt left of the
/// house, and (2026-11-16) a pinned row whose own icon (a site favicon: "Spotify", "standup") took the pin's place showed
/// no pin at all, so it did not read as pinned. The contract: every pinned row and pinned group draws its pin, centered
/// under Home's glyph and as large as the house; a text-only pinned row's title starts at Home's label x; a pinned row's
/// own icon or dot centers one column after the pin and its title one column after Home's label. At 1x and 2x, every
/// density, Minimal Mode and text size.
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
    /// A pinned group with no icon, in the list under the Pinned block (``list(scale:width:pinnedGroup:)``).
    static let pinnedGroupID = GroupID("g-share-home-line")

    static func list(scale: CGFloat, width: CGFloat = 240, pinnedGroup: Bool = false) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [home])
        let pinned = SidebarLayoutDocument.pinnedSection(items: pins)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
            SidebarSection(kind: .custom(SidebarCustomSection(id: pinned.id.rawValue)), nodes: []),
        ] + (pinnedGroup ? [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .group(SidebarGroup(id: pinnedGroupID, name: "Pinned group", color: .blue, isPinned: true,
                                workspaces: [SidebarWorkspace(id: WorkspaceID("w-share-home-line"), title: "w")])),
        ])] : []))
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
    static func at(_ c: Case, preset: DensityPreset = .compact, _ body: () throws -> Void) throws {
        // Release closed views between synchronous cases before the next motion notification.
        try autoreleasepool {
            Motion.reduceMotionOverride = true
            defer { Motion.reduceMotionOverride = nil }
            TunableStore.shared.activate(file: nil)
            TunableStore.shared.register(SidebarTunables.all)
            TunableStore.shared.set(SidebarPinnedRowLeading.tunable.key, nil)
            try #require(SidebarPinnedRowLeading.tunable.value == .pinThenIcon, "the default look is pinThenIcon")
            try DensityTokens.$scoped.withValue(preset.tokens) {
                try SidebarGroupRailAlignmentTests.with(c.density, c.minimal, textSize: c.textSize, body)
            }
        }
    }

    /// https://github.com/manaflow-ai/cmux/issues/42431: every pinned row's leading glyph, its pin, centers on Home's
    /// glyph's center line. A left-edge check passed while the pin, taller than it is wide, hugged the column's left
    /// edge with its middle 3 pt left of the house's, the globe's and the app icons'.
    @Test(arguments: cases, DensityPreset.allCases)
    func everyPinnedRowsLeadingGlyphCentersUnderHomes(_ c: Case, preset: DensityPreset) throws {
        try Self.at(c, preset: preset) {
            let (list, window) = Self.list(scale: c.scale)
            defer { window.close() }
            let home = try HomePinnedRowAlignmentTests.item(list, Self.home.id)
            // The optical glyph square every row glyph centers in starts on the icon column's edge and fits in it: the
            // tuned glyph size (SidebarRowTuning.glyphSize) is 1 to 2 pt under the column's width, so the
            // center line is the square's, not the column's (a pinned group's pin keeps it too, below).
            #expect(SidebarStyle.rowGlyphOpticalSide <= SidebarStyle.iconColumnBox + 0.5,
                    "\(c.testDescription): the optical glyph square is \(SidebarStyle.rowGlyphOpticalSide), wider than the icon column \(SidebarStyle.iconColumnBox)")
            let homeInk = list.convert(try #require(home.glyphInkFrame, "Home drew no glyph"), from: home)
            let tolerance = 1 / c.scale
            for item in Self.pins {
                let row = try HomePinnedRowAlignmentTests.item(list, item.id)
                let ink = list.convert(try #require(row.leadingInkFrame, "\(item.id.rawValue) draws nothing in the leading column"), from: row)
                #expect(abs(ink.midX - homeInk.midX) <= tolerance,
                        "\(c.testDescription): \(item.id.rawValue)'s leading glyph centers at \(ink.midX), Home's at \(homeInk.midX)")
            }
        }
    }

    /// The pin's ink is as large as the house's along its longer side, so it reads as one size with it, not 4 pt smaller.
    /// A pinned group's pin draws on the same line and at the same size as a pinned workspace row's: centered under Home's
    /// glyph, its ink as large as the house's. It centered on the icon column's middle, which (glyphs 1 to 2 pt
    /// under the column's width) sits 1 pt right of the line Home and the pinned rows share.
    @Test(arguments: cases, DensityPreset.allCases)
    func aPinnedGroupsPinCentersUnderHomes(_ c: Case, preset: DensityPreset) throws {
        try Self.at(c, preset: preset) {
            let (list, window) = Self.list(scale: c.scale, pinnedGroup: true)
            defer { window.close() }
            let home = try HomePinnedRowAlignmentTests.item(list, Self.home.id)
            let homeInk = list.convert(try #require(home.glyphInkFrame, "Home drew no glyph"), from: home)
            let rowPin = try HomePinnedRowAlignmentTests.item(list, Self.plain.id)
            let rowInk = list.convert(try #require(rowPin.pinInkFrame, "the text-only pinned row draws no pin"), from: rowPin)
            let header = try #require(list.rowViews[.group(Self.pinnedGroupID)] as? GroupHeaderRowView, "no pinned group header")
            header.needsLayout = true
            header.layoutSubtreeIfNeeded()
            let groupInk = list.convert(try #require(header.pinInkFrame, "the pinned group draws no pin"), from: header)
            let tolerance = 1 / c.scale
            #expect(abs(groupInk.midX - homeInk.midX) <= tolerance,
                    "\(c.testDescription): the pinned group's pin centers at \(groupInk.midX), Home's glyph at \(homeInk.midX)")
            #expect(abs(groupInk.height - rowInk.height) <= tolerance,
                    "\(c.testDescription): the pinned group's pin is \(groupInk.height) pt tall, a pinned row's \(rowInk.height) pt")
        }
    }

    @Test(arguments: cases, DensityPreset.allCases)
    func thePinDrawsAsLargeAsHomesGlyph(_ c: Case, preset: DensityPreset) throws {
        try Self.at(c, preset: preset) {
            let (list, window) = Self.list(scale: c.scale)
            defer { window.close() }
            let home = try HomePinnedRowAlignmentTests.item(list, Self.home.id)
            let plain = try HomePinnedRowAlignmentTests.item(list, Self.plain.id)
            let pin = try #require(plain.pinInkFrame, "the text-only pinned row draws no pin")
            let house = try #require(home.glyphInkFrame, "Home drew no glyph")
            #expect(abs(SidebarOpticalGlyph.fittedExtent(pin.size) - SidebarOpticalGlyph.fittedExtent(house.size)) <= 1,
                    "\(c.testDescription): the pin's ink is \(pin.width) x \(pin.height) pt, Home's \(house.width) x \(house.height) pt")
        }
    }

    /// https://github.com/manaflow-ai/cmux/issues/42431 (2026-11-16): a pinned row with its own icon (a site favicon such
    /// as Spotify's, an emoji, a color dot) drew that icon in the pin's place and no pin, so it did not read as pinned.
    /// Every pinned row draws its pin under Home's glyph; its own icon centers one column after the pin, and its title
    /// starts one column after Home's label. A text-only pinned row's title starts at Home's label x.
    @Test(arguments: cases, DensityPreset.allCases)
    func everyPinnedRowShowsItsPinThenItsOwnIcon(_ c: Case, preset: DensityPreset) throws {
        try Self.at(c, preset: preset) {
            let (list, window) = Self.list(scale: c.scale)
            defer { window.close() }
            let home = try HomePinnedRowAlignmentTests.item(list, Self.home.id)
            let homeInk = list.convert(try #require(home.glyphInkFrame, "Home drew no glyph"), from: home)
            let homeX = list.convert(home.titleFrame, from: home).minX
            // One column step: from Home's icon column to its label, as from the pin's column to the next one.
            let step = homeX - list.convert(home.leadingColumnFrame, from: home).minX
            let tolerance = 1 / c.scale
            var iconMids: [(String, CGFloat)] = [], titles: [(String, CGFloat)] = []
            for item in Self.pins {
                let name = item.id.rawValue
                let row = try HomePinnedRowAlignmentTests.item(list, item.id)
                let pin = list.convert(try #require(row.pinInkFrame, "\(c.testDescription): \(name) draws no pin"), from: row)
                #expect(abs(pin.midX - homeInk.midX) <= tolerance,
                        "\(c.testDescription): \(name)'s pin centers at \(pin.midX), Home's glyph at \(homeInk.midX)")
                let title = list.convert(row.titleFrame, from: row).minX
                guard item.id != Self.plain.id else {
                    #expect(row.ownIconInkFrame == nil, "\(c.testDescription): the text-only pinned row draws an icon")
                    #expect(abs(title - homeX) <= 0.5, "\(c.testDescription): \(name)'s title starts at \(title), Home's label at \(homeX)")
                    continue
                }
                let icon = list.convert(try #require(row.ownIconInkFrame, "\(c.testDescription): \(name) draws no icon"), from: row)
                #expect(icon.minX >= pin.maxX, "\(c.testDescription): \(name)'s icon starts at \(icon.minX), inside its pin (ends \(pin.maxX))")
                #expect(icon.maxX <= title, "\(c.testDescription): \(name)'s icon ends at \(icon.maxX), past its title at \(title)")
                #expect(abs(icon.midX - (pin.midX + step)) <= tolerance,
                        "\(c.testDescription): \(name)'s icon centers at \(icon.midX), one column after its pin at \(pin.midX + step)")
                #expect(abs(title - (homeX + step)) <= 0.5,
                        "\(c.testDescription): \(name)'s title starts at \(title), one column after Home's label at \(homeX + step)")
                iconMids.append((name, icon.midX)); titles.append((name, title))
            }
            // The emoji, the dot and the favicon share one center line and one title x.
            for (name, mid) in iconMids.dropFirst() {
                #expect(abs(mid - iconMids[0].1) <= tolerance, "\(c.testDescription): \(name)'s icon centers at \(mid), \(iconMids[0].0)'s at \(iconMids[0].1)")
            }
            for (name, x) in titles.dropFirst() {
                #expect(abs(x - titles[0].1) <= 0.5, "\(c.testDescription): \(name)'s title starts at \(x), \(titles[0].0)'s at \(titles[0].1)")
            }
        }
    }

    /// A pinned group with its own icon keeps its pin where an iconless pinned group draws it, with the icon in the next
    /// column and its name after that (https://github.com/manaflow-ai/cmux/issues/42431: the icon took the pin's place).
    @Test(arguments: cases, DensityPreset.allCases)
    func aPinnedGroupWithAnIconKeepsItsPin(_ c: Case, preset: DensityPreset) throws {
        try Self.at(c, preset: preset) {
            let (plain, icon, list, window) = try Self.pinnedGroups(scale: c.scale)
            defer { window.close() }
            let plainPin = list.convert(try #require(plain.pinInkFrame, "the iconless pinned group draws no pin"), from: plain)
            let iconPin = list.convert(try #require(icon.pinInkFrame, "\(c.testDescription): the pinned group with an icon draws no pin"), from: icon)
            #expect(abs(iconPin.midX - plainPin.midX) <= 1 / c.scale,
                    "\(c.testDescription): the pinned group's pin centers at \(iconPin.midX) with an icon, \(plainPin.midX) without one")
            let glyph = list.convert(icon.glyph.frame, from: icon)
            #expect(!icon.glyph.isHidden && glyph.minX >= iconPin.maxX,
                    "\(c.testDescription): the group's icon starts at \(glyph.minX), inside its pin (ends \(iconPin.maxX))")
            let plainName = list.convert(plain.name.frame, from: plain).minX, iconName = list.convert(icon.name.frame, from: icon).minX
            #expect(iconName >= glyph.maxX - 0.5 && iconName > plainName + 0.5,
                    "\(c.testDescription): the group's name starts at \(iconName), its icon ends at \(glyph.maxX), an iconless group's name at \(plainName)")
        }
    }

    /// The Debug `ownIcon` look (`sidebar.pinnedRowLeading`, kept for comparison) draws a pinned row's own icon or dot in
    /// the pin's place, centered under Home's glyph, with its title at Home's label x; a text-only row keeps its pin.
    @Test(arguments: [Case(density: .compact, minimal: .off, textSize: .standard, scale: 2),
                      Case(density: .comfortable, minimal: .off, textSize: .standard, scale: 1)])
    func theOwnIconLookPutsTheIconInThePinsPlace(_ c: Case) throws {
        try Self.at(c) {
            let key = SidebarPinnedRowLeading.tunable.key
            defer { TunableStore.shared.set(key, nil) }
            try #require(TunableStore.shared.set(key, SidebarPinnedRowLeading.ownIcon.tunableValue) == SidebarPinnedRowLeading.ownIcon.tunableValue)
            let (list, window) = Self.list(scale: c.scale)
            defer { window.close() }
            let home = try HomePinnedRowAlignmentTests.item(list, Self.home.id)
            let homeInk = list.convert(try #require(home.glyphInkFrame), from: home)
            let homeX = list.convert(home.titleFrame, from: home).minX
            for item in Self.pins {
                let row = try HomePinnedRowAlignmentTests.item(list, item.id)
                let ink = list.convert(try #require(row.leadingInkFrame, "\(item.id.rawValue) draws nothing"), from: row)
                #expect((row.pinInkFrame != nil) == (item.id == Self.plain.id), "\(c.testDescription): \(item.id.rawValue)'s pin")
                #expect(abs(ink.midX - homeInk.midX) <= 1 / c.scale,
                        "\(c.testDescription): \(item.id.rawValue)'s leading glyph centers at \(ink.midX), Home's at \(homeInk.midX)")
                let x = list.convert(row.titleFrame, from: row).minX
                #expect(abs(x - homeX) <= 0.5, "\(c.testDescription): \(item.id.rawValue)'s title starts at \(x), Home's label at \(homeX)")
            }
            let (plain, icon, groups, groupWindow) = try Self.pinnedGroups(scale: c.scale)
            defer { groupWindow.close() }
            #expect(icon.pinSquareFrame == nil, "\(c.testDescription): the pinned group with an icon still draws its pin")
            let plainName = groups.convert(plain.name.frame, from: plain).minX, iconName = groups.convert(icon.name.frame, from: icon).minX
            #expect(abs(plainName - iconName) <= 0.5, "\(c.testDescription): the group's name starts at \(iconName) with an icon, \(plainName) without one")
        }
    }

    /// Two pinned groups in a machine section, one plain and one with an emoji icon, laid out in a window of `scale`.
    static func pinnedGroups(scale: CGFloat) throws -> (plain: GroupHeaderRowView, icon: GroupHeaderRowView, list: SidebarListView, window: NSWindow) {
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
        window.testScale = scale
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.rowViews.values.forEach { $0.needsLayout = true; $0.layoutSubtreeIfNeeded() }
        guard let plain = list.rowViews[.group(plainID)] as? GroupHeaderRowView,
              let icon = list.rowViews[.group(iconID)] as? GroupHeaderRowView else {
            window.close()
            throw PinnedGroupsMissing()
        }
        return (plain, icon, list, window)
    }

    struct PinnedGroupsMissing: Error, CustomStringConvertible { var description: String { "no pinned group headers laid out" } }
}
