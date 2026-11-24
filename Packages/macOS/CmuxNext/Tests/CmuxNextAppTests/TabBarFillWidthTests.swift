import AppKit
@testable import CmuxNextTabs
import CmuxNextDesign
import Testing

/// The pane toolbar must give a tab strip the width its controls actually occupy at the pane cap.
/// Reserving the full intrinsic width when controls fold leaves a browser strip needlessly narrow.
@MainActor @Suite struct TabBarFillWidthTests {
    @Test func cappedToolbarUsesItsFittedWidth() {
        let view = PaneToolbarView()
        let wideTool = PaneTabRowTool(id: "wide", symbol: "globe", label: "Wide browser control",
                                      text: "A control wider than the narrow pane")
        view.show(more: true, nativeItems: [wideTool])

        let paneWidth: CGFloat = 60
        let cap = paneWidth / 2
        let fitted = view.tabRowWidth(fitting: cap)

        #expect(fitted < cap, "the folded control leaves only the visible trailing slot: (fitted) vs (cap)")
        #expect(view.paneWidth(in: paneWidth, sharing: false) == fitted,
                "the strip gets the fitted toolbar width, not the full half-pane cap")
    }
}
