import AppKit
@testable import CmuxNextApp
@testable import CmuxNextTabs
import Testing

/// DP1 (tab conservation) judges only strips that are shown. A strip out of sight (a pane with
/// its tab bar hidden, a parked workspace's) lays out no model change until it shows again
/// (``TabStripView/syncFromModel()``), so a tab added or closed meanwhile by Cmd-T, a script or
/// another client is not a desync, and the strip shown again shows the pane's tabs.
@MainActor @Suite(.serialized) struct TabConservationHiddenStripTests {
    @Test func aHiddenStripWhoseModelChangedIsNoViolationHiddenOrShownAgain() throws {
        let model = TabStripModel(tabs: (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }, selectedID: TabID("tab0"))
        let strip = TabStripView(model: model)
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 40))
        strip.frame = NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight)
        pane.addSubview(strip)
        let window = NSWindow(contentRect: pane.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = pane
        strip.layoutSubtreeIfNeeded()
        #expect(InputInvariantMonitor.stripMismatch(strip, holds: model.orderedTabs.map(\.id)) == nil)

        // Hide Tab Bar: the pane hides its strip (PaneContentView.layout), then a tab opens and one closes.
        strip.isHidden = true
        model.tabs.append(TabItem(id: TabID("tab3"), title: "Tab 3"))
        model.tabs.removeAll { $0.id == TabID("tab1") }
        strip.syncFromModel() // as the App's pane apply calls it
        #expect(InputInvariantMonitor.stripMismatch(strip, holds: model.orderedTabs.map(\.id)) == nil,
                "a strip with its tab bar hidden is reported as a tab conservation desync")

        strip.isHidden = false
        #expect(InputInvariantMonitor.stripMismatch(strip, holds: model.orderedTabs.map(\.id)) == nil,
                "the strip shown again does not show its pane's tabs")

        // A shown strip that lags its model is still a violation (the check is not vacuous): a tab
        // added with no sync yet (its observation runs on a later turn) is held but not shown.
        model.tabs.append(TabItem(id: TabID("tab4"), title: "Tab 4"))
        let mismatch = try #require(InputInvariantMonitor.stripMismatch(strip, holds: model.orderedTabs.map(\.id)))
        #expect(mismatch.contains("tab4"))
        _ = window
    }
}
