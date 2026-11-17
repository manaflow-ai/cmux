import AppKit
@testable import CmuxNextTabs
import Testing

/// Every pane holds a zoom indicator that stays hidden, with no size, until its pane zooms. AppKit
/// lays that hidden view out too: with its pane, and again at each change of the appearance. An
/// inset of a rect smaller than the inset is the null rect, whose origin is infinite, and a view
/// must never get it as its frame (AppKit logs a fault for each infinite coordinate of a frame).
/// So an indicator with no room for its button has no frame for it.
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

    /// The frame that AppKit keeps for the button of a new, hidden indicator after `layout()`. The
    /// case prints it, for the run's log.
    @Test func aHiddenIndicatorsLayoutKeepsItsButtonsFrameFinite() {
        let indicator = Self.indicator()
        #expect(indicator.isHidden && indicator.bounds.isEmpty, "a new indicator is hidden and has no size")

        indicator.layout()

        let frame = indicator.button.frame
        print("PaneZoomIndicatorHiddenLayoutTests: the button's frame after layout() with no size: \(frame)")
        #expect(frame.origin.x.isFinite && frame.origin.y.isFinite, "the button's frame has an infinite origin: \(frame)")
    }

    private static func indicator() -> PaneZoomIndicatorView {
        PaneZoomIndicatorView(model: TabStripModel(tabs: [TabItem(id: TabID("tab"), title: "Tab")]))
    }
}
