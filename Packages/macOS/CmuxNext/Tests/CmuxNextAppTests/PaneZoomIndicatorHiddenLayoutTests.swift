import AppKit
@testable import CmuxNextTabs
import Testing

/// Every pane holds a zoom indicator that stays hidden, with no size, until its pane zooms. Its
/// `layout()` can run in that state (its override for a change of the appearance asks for one). An
/// inset of a rect smaller than the inset is the null rect, whose origin is infinite, and a view
/// must never get it as its frame (AppKit does not keep it: the button lands far outside its pane).
/// So an indicator with no room for its button has no frame for it, and its `layout()` sets none.
/// No window: each case makes at most the indicator alone and calls its `layout()`.
@MainActor @Suite struct PaneZoomIndicatorHiddenLayoutTests {
    @Test func anIndicatorWithNoSizeHasNoFrameForItsButton() {
        let frame = PaneZoomIndicatorView.buttonFrame(in: .zero)
        #expect(frame == nil, "an indicator with no size gives its button the frame \(String(describing: frame))")
    }

    /// The shown indicator's size: the button fills it but for the glass's padding.
    @Test func aSizedIndicatorInsetsItsButtonByThePadding() {
        let indicator = Self.indicator()
        indicator.frame = NSRect(origin: .zero, size: PaneZoomIndicatorView.size)
        let padding = PaneZoomIndicatorView.padding
        let inset = indicator.bounds.insetBy(dx: padding, dy: padding)
        #expect(PaneZoomIndicatorView.buttonFrame(in: indicator.bounds) == inset)

        indicator.layout()

        #expect(indicator.button.frame == inset)
    }

    /// The `layout()` of a new, hidden indicator must leave its button's frame as it was. Without
    /// this case, a `layout()` that insets the bounds itself passes the two cases above. The case
    /// prints the frame that the button has after `layout()`, for the run's log.
    @Test func aHiddenIndicatorsLayoutLeavesItsButtonsFrame() {
        let indicator = Self.indicator()
        #expect(indicator.isHidden && indicator.bounds.isEmpty, "a new indicator is hidden and has no size")
        let before = indicator.button.frame

        indicator.layout()

        let frame = indicator.button.frame
        print("PaneZoomIndicatorHiddenLayoutTests: the button's frame after layout() with no size: \(frame)")
        #expect(frame == before, "layout() with no size moved the button's frame from \(before) to \(frame)")
    }

    private static func indicator() -> PaneZoomIndicatorView {
        PaneZoomIndicatorView(model: TabStripModel(tabs: [TabItem(id: TabID("tab"), title: "Tab")]))
    }
}
