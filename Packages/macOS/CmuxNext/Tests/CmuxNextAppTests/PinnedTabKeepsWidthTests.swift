import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Aziz 2026-11-09: "The horizontal tab width shrinks when I pin and it lacks a pin indicator." Pinning a
/// tab in the horizontal strip collapsed it to an icon-only sliver with no mark that it was pinned. A
/// pinned tab now keeps its width and title and shows a pin where an unpinned tab's x shows on hover
/// (`tabs.pinnedKeepsTitle`, on by default). With it off, the Chrome-thin icon-only pinned tab stays, and
/// it too shows a pin, on its icon's corner.
@MainActor @Suite(.serialized, .closesItsWindows) struct PinnedTabKeepsWidthTests {
    private struct Harness {
        let window: NSWindow
        let strip: TabStripView
        let model: TabStripModel
        static let target = TabID("tab1")

        init() {
            let tabs = (0..<4).map { TabItem(id: TabID("tab\($0)"), title: "Computer Use via cua-driver \($0)", icon: .symbol("doc")) }
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            model = TabStripModel(tabs: tabs, selectedID: tabs[0].id)
            strip = TabStripView(model: model)
            strip.dragsWindowFromEmptySpace = false
            strip.frame = NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight)
            window.contentView = strip
            settle()
        }

        func settle() {
            strip.sync(fromModel: true, animating: false)
            strip.layoutSubtreeIfNeeded()
            strip.layoutSubtreeIfNeeded()
        }

        /// Pins the target tab the way the tab's menu does, through the strip model's reducer.
        func pin() throws {
            try #require(model.apply(.pin(Self.target)) { TabItem(id: TabID("unused"), title: "") })
            settle()
        }

        func cell() throws -> TabCell { try #require(strip.cells[Self.target]) }

        /// The pin mark's frame in the cell while it draws, else nil.
        func pinFrame() throws -> CGRect? {
            let cell = try cell()
            // By name, not `pinLayer`, so this test compiles at the base and shows the bug there.
            guard let pin = cell.layer.sublayers?.first(where: { $0.name == "tabs.pinMark" }),
                  pin.opacity > 0, pin.contents != nil else { return nil }
            return pin.frame
        }
    }

    private static let pinnedKeepsTitleKey = TabTunables.pinnedKeepsTitle.key

    private static func withPinnedKeepsTitle(_ on: Bool, _ body: () throws -> Void) throws {
        // The store refuses a key it has no descriptor for (the app registers TabTunables.all at launch).
        TunableStore.shared.register([TabTunables.pinnedKeepsTitle.descriptor])
        try #require(TunableStore.shared.set(Self.pinnedKeepsTitleKey, .bool(on)) == .bool(on))
        defer { _ = TunableStore.shared.set(Self.pinnedKeepsTitleKey, nil) }
        try body()
    }

    @Test func pinningKeepsTheTabsWidthAndTitleAndShowsAPin() throws {
        DesignSettings.shared.tabOverflow = .shrink
        try Self.withPinnedKeepsTitle(true) {
            let harness = Harness()
            defer { harness.window.closeAfterTest() }
            let before = try #require(harness.strip.result.slot(Harness.target)).width
            #expect(try harness.pinFrame() == nil, "an unpinned tab draws a pin")
            try harness.pin()
            let slot = try #require(harness.strip.result.slot(Harness.target))
            #expect(slot.isPinned)
            #expect(slot.width >= before - 1, "pinning narrowed the tab from \(before) pt to \(slot.width) pt")
            let cell = try harness.cell()
            #expect(cell.visibility.showsTitle, "the pinned tab lost its title at \(slot.width) pt")
            #expect(cell.closeButtonRect == nil, "a pinned tab shows an x")
            let pin = try #require(try harness.pinFrame(), "the pinned tab draws no pin")
            // The pin sits at the trailing end, where the x would be, inside the tab's pill.
            #expect(pin.midX > cell.pillFrameInCell.midX && pin.maxX <= cell.pillFrameInCell.maxX + 0.5,
                    "the pin is at \(pin), the pill \(cell.pillFrameInCell)")
        }
    }

    @Test func iconOnlyPinnedTabsStayThinAndShowAPinOnTheIcon() throws {
        DesignSettings.shared.tabOverflow = .shrink
        try Self.withPinnedKeepsTitle(false) {
            let harness = Harness()
            defer { harness.window.closeAfterTest() }
            try harness.pin()
            let slot = try #require(harness.strip.result.slot(Harness.target))
            #expect(slot.width == harness.strip.metrics.pinnedTabWidth)
            let cell = try harness.cell()
            #expect(!cell.visibility.showsTitle)
            let pin = try #require(try harness.pinFrame(), "the icon-only pinned tab draws no pin")
            let icon = cell.iconLayer.frame
            #expect(pin.intersects(icon.insetBy(dx: -2, dy: -2)), "the pin \(pin) is not on the icon \(icon)")
        }
    }

    /// Titled pinned tabs are as wide as the others, so in Scroll mode three of them could fill most of a
    /// narrow pane: the fixed band then leaves the other tabs at least half the strip, or fixes nothing.
    @Test func widePinnedTabsNeverLeaveTheOtherTabsLessThanHalfTheStrip() {
        var metrics = TabStripMetrics()
        metrics.pinnedKeepsTitle = true
        let items = (0..<13).map { TabLayoutItem(id: TabID("t\($0)"), isPinned: $0 < 3) }
        for viewport in [CGFloat(600), 900, 1400] {
            let result = TabLayoutEngine.layout(items: items, availableWidth: viewport, style: .chrome, metrics: metrics)
            let mapping = TabScrollMapping(result: result, viewportWidth: viewport, minimumScrollable: metrics.minActiveTabWidth, offset: 0)
            #expect(mapping.band * 2 <= viewport, "at \(viewport) pt the pinned band is \(mapping.band) pt")
        }
    }
}
