import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// Lucas 2026-11-12, a shot of a + in a filled rounded square beside a tab ("we want to have both, as a pill but that
/// rounding"): the tab bar's split `+ ⌄` stays one control, rounds like a button (`Metrics.controlCornerRadius`), not
/// like a pill, and shows its fill at rest. The hovered segment's fill rises; a press takes the pressed fill.
@MainActor struct TabSplitButtonLookTests {
    @Test func theSplitControlRoundsLikeAButton() {
        #expect(NewTabButtonView.splitCornerRadius == Metrics.controlCornerRadius)
    }

    @Test func bothSegmentsShowTheirFillAtRestAndItRisesUnderThePointer() {
        #expect(NewTabButtonView.splitFill(hovering: false, pressed: false) == Palette.hoverFill, "a fill at rest")
        #expect(NewTabButtonView.splitFill(hovering: true, pressed: false) == ChromeHover.raisedHoverFill, "hover rises")
        #expect(NewTabButtonView.splitFill(hovering: true, pressed: true) == Palette.pressedFill, "a press")
    }
}
