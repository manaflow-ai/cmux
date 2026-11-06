import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-10-19 (Chief msg 2833): "Close animation only for the whole pane (last tab) and
/// the whole window; tab close instant." A tab that is not its pane's last closes in one frame,
/// whatever `ui.animations.newTab` says (that switch is the open's): its cell goes in the sync that
/// drops it, the tabs left are at their new places in the same frame, and no strip move starts. A
/// width change right after it (a sidebar toggle, a pane edge) has nothing left to keep.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabCloseInstantTests {
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    static func moveKeys(_ strip: TabStripView) -> [String] {
        strip.cells.values.flatMap { ($0.layer.animationKeys() ?? []).filter { $0.hasPrefix(TabStripMove.keyPrefix) } }
    }

    /// The strip animates only in a window on screen, so the check is real only there.
    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() },
          arguments: [false, true])
    func aTabThatIsNotTheLastClosesInOneFrame(inClosingMode: Bool) throws {
        let tabs = (0..<4).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }
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
        // Synchronous from here to the resets: the overrides are process-wide.
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let enabledAnimations = DesignSettings.shared.enabledAnimations
        DesignSettings.shared.enabledAnimations.insert(.newTab)
        defer { DesignSettings.shared.enabledAnimations = enabledAnimations }
        try #require(Motion.tabs.animatesMovement, "animation speed is off on this host")
        // Chrome's closing mode (a close under the pointer keeps the widths) closes at once too.
        if inClosingMode { strip.closingModeWidth = strip.result.standardWidth }

        // A middle tab: the tabs right of it would slide into its room if the close moved.
        model.tabs.remove(at: 1)
        strip.sync(fromModel: true)

        #expect(strip.cells[TabID("tab1")] == nil, "the closed tab stayed on screen to shrink out")
        #expect(!strip.dying.contains(TabID("tab1")), "the closed tab is still closing")
        #expect(Self.moveKeys(strip).isEmpty, "the close started strip moves: \(Self.moveKeys(strip))")
        for slot in strip.result.slots {
            guard let cell = strip.cells[slot.id] else { continue }
            let shown = (cell.layer.presentation() ?? cell.layer).frame
            #expect(abs(cell.layer.frame.minX - shown.minX) < 0.5, "\(slot.id.rawValue) is not at its place in the close's frame")
        }
        // The sidebar shows right after: nothing of the close is left to snap.
        strip.setFrameSize(NSSize(width: 520, height: strip.frame.height))
        strip.layoutSubtreeIfNeeded()
        #expect(strip.cells[TabID("tab1")] == nil)
    }
}
