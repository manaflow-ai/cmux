@testable import CmuxNextBrowser
import Foundation
import Testing

/// The page-info chip keeps its text label ("Not secure") until the focusing
/// press is released. Dropping the label at focus moved the field 77 pt left
/// under the still-down pointer (os-smoke Tart VMs, 2026-10-20), so on macOS 15
/// a drag from the resting omnibar started 77 pt off its press.
@MainActor
struct OmnibarFocusClickChipTests {
    private func reduce(_ state: OmnibarState, _ inputs: [OmnibarInput]) -> OmnibarState {
        var state = state
        for input in inputs {
            state = OmnibarReducer.reduce(state, input, resolver: OmniboxResolver()).state
        }
        return state
    }

    @Test func theChipKeepsItsLabelUntilTheFocusingPressIsReleased() throws {
        let rest = OmnibarState(pageURL: try #require(URL(string: "http://example.com/a")))
        #expect(OmnibarPresentation(rest).chip == .page(focused: false))
        let pressed = reduce(rest, [.fieldMouseDown(clickCount: 1), .focusGained(.mouse)])
        #expect(pressed.hasFocus)
        #expect(OmnibarPresentation(pressed).chip == .page(focused: false))
        let released = reduce(pressed, [.fieldMouseUp])
        #expect(OmnibarPresentation(released).chip == .page(focused: true))
    }

    /// Keyboard focus (Cmd-L) drops the label at once, as before.
    @Test func keyboardFocusDropsTheLabelAtOnce() throws {
        let rest = OmnibarState(pageURL: try #require(URL(string: "http://example.com/a")))
        let focused = reduce(rest, [.focusGained(.keyboard)])
        #expect(OmnibarPresentation(focused).chip == .page(focused: true))
    }
}
