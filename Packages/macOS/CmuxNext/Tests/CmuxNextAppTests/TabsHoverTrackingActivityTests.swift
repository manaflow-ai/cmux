import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// p14-energy-055b (Q5): the tab strip, the saved groups bar and the group editor's controls
/// hover only while cmux is the active app, so a mouse move over an inactive cmux window wakes
/// nothing (`.activeForHover`, not `.activeAlways`).
@MainActor @Suite(.serialized) struct TabsHoverTrackingActivityTests {
    private func activity(of view: NSView) -> [NSTrackingArea.Options] {
        view.trackingAreas.map { $0.options.intersection([.activeAlways, .activeInActiveApp, .activeInKeyWindow, .activeWhenFirstResponder]) }
    }

    @Test func tabsChromeTracksOnlyInTheActiveApp() {
        let saved = WindowPlacement.noActivate
        WindowPlacement.noActivate = false
        defer { WindowPlacement.noActivate = saved }

        let model = TabStripModel(tabs: [TabItem(id: TabID("tab0"), title: "Tab 0")], selectedID: TabID("tab0"))
        let strip = TabStripView.testing(model: model)
        strip.updateTrackingAreas()
        #expect(!activity(of: strip).isEmpty)
        #expect(!activity(of: strip).contains(.activeAlways), "the tab strip wakes for moves while cmux is inactive")
        #expect(activity(of: strip).contains(.activeInActiveApp))

        let bar = SavedGroupsBarView(model: SavedGroupsBarModel())
        #expect(activity(of: bar) == [.activeInActiveApp])

        let swatch = TabGroupSwatchView(color: .blue)
        #expect(activity(of: swatch) == [.activeInActiveApp])

        let row = TabGroupEditorRow(title: "Ungroup")
        #expect(activity(of: row) == [.activeInActiveApp])
    }
}
