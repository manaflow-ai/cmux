@testable import CmuxNextBrowser
import Foundation
import Testing

/// The focusing click selects the whole address on every macOS (report
/// 2026-10-20, "highlighting stuff in omnibar in sequoia is broken").
///
/// The field grows to the left when it takes focus, while the button is
/// still down. On macOS 15 AppKit's text tracking maps the press in the old
/// layout and the release in the new one, so a click that never moved ends
/// with a few characters selected (`[5, 13]` in the os-smoke Tart VM) where
/// macOS 26 ends with a caret. Chrome selects all on the release of a
/// focusing click unless the pointer dragged past the drag threshold
/// (`OmniboxViewViews::OnMouseReleased`, `select_all_on_mouse_release_`);
/// what AppKit selected during the click does not decide it.
@MainActor
struct OmnibarFocusClickSelectionTests {
    private func reduce(_ state: OmnibarState, _ inputs: [OmnibarInput]) -> OmnibarState {
        var state = state
        for input in inputs {
            state = OmnibarReducer.reduce(state, input, resolver: OmniboxResolver()).state
        }
        return state
    }

    private func page() throws -> OmnibarState {
        OmnibarState(pageURL: try #require(URL(string: "http://127.0.0.1:49216/omnibar/selection-probe?q=highlight")))
    }

    /// The macOS 15 path: press, focus, AppKit's tracking reports a selection
    /// of its own although the pointer never moved, release.
    @Test func aStillClickThatAppKitTurnedIntoASelectionSelectsAll() throws {
        let rest = try page()
        let focused = reduce(rest, [.fieldMouseDown(clickCount: 1), .focusGained(.mouse)])
        let text = focused.fieldText
        let shifted = reduce(focused, [
            .fieldChanged(.init(text: text, selection: NSRange(location: 5, length: 8)), nil),
            .fieldMouseUp,
        ])
        #expect(shifted.edit.selection == NSRange(location: 0, length: (shifted.fieldText as NSString).length))
    }

    /// The macOS 26 path (a caret after the click) keeps selecting all.
    @Test func aStillClickThatLeftACaretSelectsAll() throws {
        let rest = try page()
        let focused = reduce(rest, [.fieldMouseDown(clickCount: 1), .focusGained(.mouse)])
        let text = focused.fieldText
        let clicked = reduce(focused, [
            .fieldChanged(.init(text: text, selection: NSRange(location: 5, length: 0)), nil),
            .fieldMouseUp,
        ])
        #expect(clicked.edit.selection == NSRange(location: 0, length: (clicked.fieldText as NSString).length))
    }
}
