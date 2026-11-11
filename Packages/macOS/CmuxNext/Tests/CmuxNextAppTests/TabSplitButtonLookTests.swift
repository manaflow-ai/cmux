import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// Lucas 2026-11-12, a shot of a + in a rounded square beside a tab ("we want to have both, as a pill but that
/// rounding"; "it shouldnt have any colour/bakground on the group thing, only on hover"): the tab bar's split `+ ⌄`
/// stays one control and rounds like a button (`Metrics.controlCornerRadius`), not like a pill. It draws no fill at
/// rest; under the pointer the hovered segment takes the hover fill and the other a soft one; a press, the pressed fill.
@MainActor struct TabSplitButtonLookTests {
    @Test func theSplitControlRoundsLikeAButton() {
        #expect(NewTabButtonView.splitCornerRadius == Metrics.controlCornerRadius)
    }

    @Test func noFillAtRestAndTheHoveredSegmentFillsUnderThePointer() {
        #expect(NewTabButtonView.splitFill(hovering: false, pressed: false, siblingHovered: false) == nil, "no fill at rest")
        #expect(NewTabButtonView.splitFill(hovering: true, pressed: false, siblingHovered: false) == Palette.hoverFill, "the hovered half")
        #expect(NewTabButtonView.splitFill(hovering: true, pressed: true, siblingHovered: false) == Palette.pressedFill, "a press")
        let soft = NewTabButtonView.splitFill(hovering: false, pressed: false, siblingHovered: true)
        #expect(soft != nil, "the other half shows a fill under the pointer")
        #expect((soft?.alphaComponent ?? 1) < Palette.hoverFill.alphaComponent, "the other half, softer")
    }
}
