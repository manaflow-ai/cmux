import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// cx-y2uf5 (4): the tab strip relayouts at once on any width change, as a window resize wants,
/// but a sidebar toggle or the new-tab button also changes the width, and that snapped a tab
/// close in flight: the closing tab vanished in one frame. A close in flight keeps its spring.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabCloseWidthChangeTests {
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// The strip animates in a window on screen: with no screen nothing runs its springs.
    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aClosingTabKeepsItsSpringWhenTheStripWidthChanges() throws {
        let tabs = (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }
        let model = TabStripModel(tabs: tabs, selectedID: TabID("tab0"))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let strip = TabStripView(model: model)
        strip.frame = NSRect(x: 0, y: 0, width: 600, height: TabStripView.preferredHeight)
        window.contentView = strip
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        strip.layoutSubtreeIfNeeded()
        // Synchronous from here to the reset: the override is process-wide.
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        // Closing tabs share the structural `newTab` motion switch. Keep this
        // test explicit so it verifies the in-flight spring when that switch is
        // enabled without changing the product default (off on this branch).
        let enabledAnimations = DesignSettings.shared.enabledAnimations
        DesignSettings.shared.enabledAnimations.insert(.newTab)
        defer { DesignSettings.shared.enabledAnimations = enabledAnimations }
        try #require(Motion.tabs.animatesMovement, "animation speed is off on this host")

        model.tabs.removeLast()
        strip.sync(fromModel: true)
        try #require(strip.dying.contains(TabID("tab2")), "the close did not animate")
        // The sidebar shows: the strip narrows while the tab is still closing.
        strip.setFrameSize(NSSize(width: 520, height: strip.frame.height))
        strip.layoutSubtreeIfNeeded()
        #expect(strip.cells[TabID("tab2")] != nil, "the closing tab vanished when the strip narrowed")
    }
}
