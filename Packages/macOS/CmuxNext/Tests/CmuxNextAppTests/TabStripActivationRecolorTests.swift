import AppKit
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// A window becoming or leaving main changes one thing in its tab strip: how strongly the
/// selected tab shows its fill (dimmer in back, never gone: Lawrence 2026-10-20). Every tab of every strip used to re-resolve its theme and recolor itself
/// on each activation (where a DEV build's 10 s watchdog hang was sampled, cosmic-gray
/// 2026-10-14), so activation repaints the selected tab only, however many tabs the strip holds.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabStripActivationRecolorTests {
    static let tabs = 300

    /// Marks every unselected tab's title with a color no theme draws: a tab that repaints
    /// replaces it.
    static let sentinel = CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)

    @Test func activationRepaintsOnlyTheSelectedTab() throws {
        let model = TabStripModel(tabs: (0..<Self.tabs).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") },
                                  selectedID: TabID("tab1"))
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = strip
        window.orderFrontRegardless()
        defer { window.closeAfterTest() }
        strip.layoutSubtreeIfNeeded()
        #expect(strip.cells.count == Self.tabs)
        let selected = try #require(strip.cells[TabID("tab1")])
        let others = strip.cells.filter { $0.key != TabID("tab1") }.map(\.value)

        // What the strip's observer reports when AppKit posts didBecomeMain / didResignMain for
        // its window (driven directly: tests never post to the process-global center).
        strip.windowMain.changed(isMain: true)
        #expect(selected.backgroundLayer.backgroundColor != nil, "the main window's selected tab is filled")

        for cell in others { cell.titleLayer.foregroundColor = Self.sentinel }
        let clock = ContinuousClock()
        let resign = clock.measure { strip.windowMain.changed(isMain: false) }
        let back = selected.backgroundLayer.backgroundColor.map { $0.alpha } ?? 0
        #expect(back > 0, "a window in back still fills its selected tab, dimmer")
        let become = clock.measure { strip.windowMain.changed(isMain: true) }
        #expect(selected.backgroundLayer.backgroundColor != nil, "the fill is back when the window is main again")

        let repainted = others.filter { $0.titleLayer.foregroundColor != Self.sentinel }.count
        print("activation recolor, \(Self.tabs) tabs: resign \(resign), become \(become), \(repainted) unselected tabs repainted")
        #expect(repainted == 0, "\(repainted) of \(others.count) unselected tabs repainted for a window-main change")
    }
}
