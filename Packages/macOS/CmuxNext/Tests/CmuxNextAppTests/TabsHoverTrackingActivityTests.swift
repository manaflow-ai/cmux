import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextOnboarding
@testable import CmuxNextTabs
import CmuxNextWakeups
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

    /// The strip's area hears no exit while another app is active: cmux resigning active ends the
    /// tab hover and the plus reveal it shows.
    @Test func aDeactivationEndsTheTabStripHover() {
        _ = NSApplication.shared
        let saved = WindowPlacement.noActivate
        WindowPlacement.noActivate = false
        let center = NotificationCenter()
        PointerHover.observe(AppEvents(center: center), keyWindow: { nil })
        defer {
            PointerHover.observe(nil)
            WindowPlacement.noActivate = saved
        }

        let model = TabStripModel(tabs: [TabItem(id: TabID("tab0"), title: "Tab 0")], selectedID: TabID("tab0"))
        let strip = TabStripView.testing(model: model)
        strip.buttonReveal.pointerInStrip = true
        strip.setHovered(TabID("tab0"))
        #expect(strip.hoveredID == TabID("tab0"))

        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(strip.hoveredID == nil, "a tab stayed hovered after cmux resigned active")
        #expect(!strip.buttonReveal.pointerInStrip, "the plus stayed revealed after cmux resigned active")
        #expect(strip.reveal.deactivationWatch == nil, "the strip kept its deactivation watch after its hover ended")
    }

    /// The System Settings drag panel floats over that app with cmux in the background: its tile and
    /// close button keep hovering there (`.activeAlways`, bounded by the panel showing).
    @Test func theHelperDragPanelHoversOverSystemSettings() {
        let tile = HelperAppTile(appURL: URL(fileURLWithPath: "/Applications/cmux.app"), icon: nil)
        tile.updateTrackingAreas()
        #expect(activity(of: tile).contains(.activeAlways))

        let close = HelperPanelCloseButton(target: nil, action: nil)
        close.updateTrackingAreas()
        #expect(activity(of: close).contains(.activeAlways))
    }
}
