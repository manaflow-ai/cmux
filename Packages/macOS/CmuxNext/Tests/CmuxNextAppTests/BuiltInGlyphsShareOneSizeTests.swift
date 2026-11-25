import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lucas 2026-11-16: "the home icon is smaller than the app store icon. the home icon should increase in size to match
/// the app store icon". The built-in rows' glyphs (Home's house, the App Store's bag) draw one height at every density,
/// measured from their drawn pixels, at the rows' optical size.
@MainActor @Suite(.serialized, .closesItsWindows) struct BuiltInGlyphsShareOneSizeTests {
    @Test(arguments: DensityPreset.allCases)
    func homeAndAppStoreDrawOneHeight(preset: DensityPreset) throws {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        _ = NSApplication.shared
        let home = LayoutItem(id: LayoutItemID("itm_probe_home"), ref: .builtIn(.home))
        let store = LayoutItem(id: LayoutItemID("itm_probe_store"), ref: .builtIn(.appStore))
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [home, store])
        let infos: [LayoutItemID: SidebarItemInfo] = [home.id: .fallback(for: home), store.id: .fallback(for: store)]
        let model = SidebarModel(sections: [SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: [])])
        let list = SidebarListView(model: model)
        var metrics = SidebarRegionMetrics.standard
        metrics.trailingTrim = SidebarStyle.rowTrailingTrim
        list.blocks = SidebarListBlocks(sections: [top.id.rawValue: top], infos: infos, collapsed: [],
                                        look: .quiet, metrics: metrics, drawsLines: false, appHeights: [:])
        let window = TwoXWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        for region in list.blockRegions { region.itemViews.values.forEach { $0.layoutSubtreeIfNeeded(); $0.layout() } }
        var heights: [CGFloat] = []
        for item in [home, store] {
            let row = try HomePinnedRowAlignmentTests.item(list, item.id)
            let ink = try #require(try SidebarRowGlyphOpticalSizeTests.inkBox(row.icon), "\(preset): \(item.id.rawValue) drew nothing")
            heights.append(ink.height)
            #expect(abs(ink.height - SidebarStyle.rowGlyphOpticalSide) <= 1,
                    "\(preset): \(item.id.rawValue)'s ink is \(ink.width) x \(ink.height), the rows' optical size \(SidebarStyle.rowGlyphOpticalSide)")
        }
        #expect(abs(heights[0] - heights[1]) <= 0.5, "\(preset): Home's glyph is \(heights[0]) tall, the App Store's \(heights[1])")
    }
}
