import AppKit
@testable import CmuxNextTabs
import Testing

/// Every pane holds a zoom indicator that stays hidden, with no size, until its pane zooms. AppKit
/// lays that hidden view out too: with its pane, and again at each change of the appearance. An
/// inset of a rect smaller than the inset is the null rect, whose origin is infinite, and a view
/// must never get it as its frame (AppKit logs a fault for each infinite coordinate of a frame).
/// No window: each case makes the indicator alone and calls its `layout()`.
@MainActor @Suite struct PaneZoomIndicatorHiddenLayoutTests {
    @Test func aHiddenIndicatorWithNoSizeKeepsItsButtonsFrameFinite() {
        let indicator = Self.indicator()
        #expect(indicator.isHidden && indicator.bounds.isEmpty, "a new indicator is hidden and has no size")

        indicator.layout()

        let frame = indicator.button.frame
        #expect(frame.origin.x.isFinite && frame.origin.y.isFinite, "the button's frame has an infinite origin: \(frame)")
    }

    /// The shown indicator's size: the button fills it but for the glass's padding.
    @Test func aSizedIndicatorInsetsItsButtonByThePadding() {
        let indicator = Self.indicator()
        indicator.frame = NSRect(origin: .zero, size: PaneZoomIndicatorView.size)

        indicator.layout()

        let padding = PaneZoomIndicatorView.padding
        #expect(indicator.button.frame == indicator.bounds.insetBy(dx: padding, dy: padding))
    }

    private static func indicator() -> PaneZoomIndicatorView {
        PaneZoomIndicatorView(model: TabStripModel(tabs: [TabItem(id: TabID("tab"), title: "Tab")]))
    }
}
