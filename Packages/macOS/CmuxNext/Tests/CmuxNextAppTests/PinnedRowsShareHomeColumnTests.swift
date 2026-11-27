import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Pinned rows beside Home in the sidebar document's top: https://github.com/manaflow-ai/cmux/issues/38061 lined a
/// pinned row's leading pin up under Home's house. Leo 2026-11-23 (ask c-b5d3e0efb6) took the pin away: a pinned row
/// leads as its workspace row does, its own icon (if any) in the leading column and its title after it, at 1x and 2x,
/// every density, Minimal Mode and text size.
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
            try #require(SidebarPinnedRowLeading.tunable.value == .ownIcon, "the default look is ownIcon")
            try DensityTokens.$scoped.withValue(preset.tokens) {
                try SidebarGroupRailAlignmentTests.with(c.density, c.minimal, textSize: c.textSize, body)
            }
        }
    }

    /// Leo 2026-11-23, ask c-b5d3e0efb6 ("it puts a symbol at the left. immediately questionable"): no pinned row and
    /// no pinned group header draws a pin; each leads as its unpinned row does.
    @Test(arguments: cases, DensityPreset.allCases)
    func noPinnedRowOrGroupDrawsAPin(_ c: Case, preset: DensityPreset) throws {
        try Self.at(c, preset: preset) {
            let (list, window) = Self.list(scale: c.scale, pinnedGroup: true)
            defer { window.contentView = nil; window.close() }
            for item in Self.pins {
                let row = try HomePinnedRowAlignmentTests.item(list, item.id)
                #expect(row.pinSquareFrame == nil, "\(c.testDescription): \(item.id.rawValue) draws a pin")
            }
            let header = try #require(list.rowViews[.group(Self.pinnedGroupID)] as? GroupHeaderRowView, "no pinned group header")
            header.needsLayout = true
            header.layoutSubtreeIfNeeded()
            #expect(header.pinSquareFrame == nil, "\(c.testDescription): the pinned group header draws a pin")
        }
    }

    /// A pinned row with its own icon (an emoji, a shown page's favicon) draws it in the leading column and starts its
    /// title at Home's label x, as its workspace row does.
    @Test(arguments: cases, DensityPreset.allCases)
    func aPinnedRowWithAnIconStartsItsTitleAtHomesLabel(_ c: Case, preset: DensityPreset) throws {
        try Self.at(c, preset: preset) {
            let (list, window) = Self.list(scale: c.scale)
            defer { window.contentView = nil; window.close() }
            let home = try HomePinnedRowAlignmentTests.item(list, Self.home.id)
            let homeX = list.convert(home.titleFrame, from: home).minX
            for item in [Self.emoji, Self.page] {
                let row = try HomePinnedRowAlignmentTests.item(list, item.id)
                let x = list.convert(row.titleFrame, from: row).minX
                #expect(abs(x - homeX) <= 0.5, "\(c.testDescription): \(item.id.rawValue)'s title starts at \(x), Home's label at \(homeX)")
            }
        }
    }
}
