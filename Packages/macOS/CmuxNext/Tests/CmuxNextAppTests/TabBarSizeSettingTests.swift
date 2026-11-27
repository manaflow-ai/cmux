import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/26493: pane tab bars were too small to read, and the only
/// knob, the interface size (`appearance.metrics.chromeFontSize`), scales all chrome. cmux.json's
/// `appearance.metrics.tabFontSize` sizes tab titles on their own and `tabStripHeight` sizes the bar,
/// whose pills grow with it; a load reaches a strip that is already on screen.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabBarSizeSettingTests {
    /// Applies `metrics` the way a settings load does, with nothing else set.
    private func load(_ metrics: [String: Double] = [:], cornerPadding: Double? = nil) {
        let appearance = JSONValue.object(["metrics": .object(metrics.mapValues { .number($0) })])
        var config = ["appearance": appearance]
        if let cornerPadding { config["layout"] = .object(["cornerPadding": .number(cornerPadding)]) }
        let snapshot = CmuxConfigSnapshot.parse(.object(config), validDensities: SettingsApplier.validDensities,
                                                validMetrics: SettingsApplier.validMetrics)
        _ = SettingsApplier(registry: ActionRegistry.standard()).apply(snapshot)
    }

    private struct Harness {
        let window: NSWindow
        let strip: TabStripView

        init() {
            let tabs = (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: TabID("tab0")))
            strip.dragsWindowFromEmptySpace = false
            window.contentView = strip
            refresh()
        }

        /// What the strip's token observation does on a settings change, then a layout pass at the
        /// strip's preferred height (its pane host sizes it so).
        func refresh() {
            strip.applyTokens(animated: false)
            strip.frame = NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight)
            strip.layoutSubtreeIfNeeded()
            strip.layoutSubtreeIfNeeded()
        }

        func cell() throws -> TabCell { try #require(strip.cells[TabID("tab1")]) }
    }

    @Test func tabTextSizeSizesTabTitlesAndLeavesTheRestOfTheChrome() throws {
        defer { load() }
        load()
        let harness = Harness()
        defer { harness.window.close() }
        let body = Typography.body.pointSize
        #expect(try harness.cell().titleFont.pointSize == 14, "unset, a Default tab title is 14 pt")

        load(["tabFontSize": 16])
        harness.refresh()
        #expect(try harness.cell().titleFont.pointSize == 16)
        #expect(Typography.body.pointSize == body, "the sidebar and other chrome keep their size")
        let editor = TabInlineRename(strip: harness.strip)
        editor.begin(TabID("tab1"))
        #expect(editor.field?.font?.pointSize == 16, "renaming a tab keeps its title's size")
        editor.cancel()

        load(["tabFontSize": 40])
        harness.refresh()
        #expect(try harness.cell().titleFont.pointSize == 18, "clamped to the setting's range")
    }

    @Test func unsetTabTextSizeFollowsTheInterfaceSize() throws {
        defer { load() }
        load(["chromeFontSize": 15])
        let harness = Harness()
        defer { harness.window.close() }
        #expect(Typography.body.pointSize > 13, "the interface size reached the body size")
        #expect(try harness.cell().titleFont.pointSize > 14, "unset, a tab title grows with the interface size from Default's 14 pt")
    }

    @Test func tabBarHeightGrowsTheBarAndItsTabs() throws {
        defer { load() }
        load()
        let harness = Harness()
        defer { harness.window.close() }
        let barHeight = TabStripView.preferredHeight
        let tabHeight = try harness.cell().frame.height
        #expect(tabHeight > 0)

        load(["tabStripHeight": 40])
        harness.refresh()
        #expect(TabStripView.preferredHeight == 40)
        #expect(try harness.cell().frame.height == tabHeight + 40 - barHeight, "the pill keeps the density's room above and below it")
        #expect(harness.strip.metrics.stripVerticalPadding == (barHeight - tabHeight) / 2)

        load(["tabStripHeight": 22])
        harness.refresh()
        #expect(try harness.cell().frame.height == tabHeight + 22 - barHeight)
    }

    @Test func cornerPaddingDerivesTheStripEvenWithAHeightOverride() throws {
        defer { load() }
        load()
        let tabHeight = Metrics.tabHeight
        for (stripHeight, padding) in [(22.0, 0.0), (40.0, 4.0)] {
            load(["tabStripHeight": stripHeight], cornerPadding: padding)
            #expect(DesignSettings.shared.paneChrome.cornerPadding == CGFloat(padding))
            #expect(DesignSettings.shared.overrides[.tabStripHeight] == CGFloat(stripHeight))
            let harness = Harness()
            defer { harness.window.close() }
            #expect(try harness.cell().frame.height == tabHeight)
            #expect(Metrics.tabStripHeight == tabHeight + 2 * CGFloat(padding) + Metrics.stripTopOutset)
            #expect(TabStripView.preferredHeight == Metrics.tabStripHeight)
        }
    }
}
