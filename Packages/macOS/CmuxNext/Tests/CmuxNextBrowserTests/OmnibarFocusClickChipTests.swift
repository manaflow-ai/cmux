@testable import CmuxNextBrowser
import Foundation
import Testing

/// The page-info chip keeps its text label ("Not secure") through the
/// focusing press and after it, as Chromium's does until the user types
/// (`LocationIconView::GetShowText`). Dropping the label at focus moved the
/// field 77 pt left under the still-down pointer (os-smoke Tart VMs,
/// 2026-10-20), and dropping it at the release still shifted the bar after
/// every click (Lawrence 2026-10-30, msg 18159).
@MainActor
struct OmnibarFocusClickChipTests {
    private func reduce(_ state: OmnibarState, _ inputs: [OmnibarInput]) -> OmnibarState {
        var state = state
        for input in inputs {
            state = OmnibarReducer.reduce(state, input, resolver: OmniboxResolver()).state
        }
        return state
    }

    @Test func theChipKeepsItsLabelThroughTheFocusingClick() throws {
        let rest = OmnibarState(pageURL: try #require(URL(string: "http://example.com/a")))
        #expect(OmnibarPresentation(rest).chip == .page)
        let pressed = reduce(rest, [.fieldMouseDown(clickCount: 1), .focusGained(.mouse)])
        #expect(pressed.hasFocus)
        #expect(OmnibarPresentation(pressed).chip == .page)
        let released = reduce(pressed, [.fieldMouseUp])
        #expect(OmnibarPresentation(released).chip == .page)
    }

    /// Keyboard focus (Cmd-L) keeps the label too; typing replaces the chip with the input's icon.
    @Test func keyboardFocusKeepsTheLabelUntilTyping() throws {
        let rest = OmnibarState(pageURL: try #require(URL(string: "http://example.com/a")))
        let focused = reduce(rest, [.focusGained(.keyboard)])
        #expect(OmnibarPresentation(focused).chip == .page)
        let typed = reduce(focused, [.fieldChanged(.init(text: "s", selection: NSRange(location: 1, length: 0)), .insert)])
        if case .input = OmnibarPresentation(typed).chip {} else { Issue.record("typing keeps the page chip") }
    }
}
