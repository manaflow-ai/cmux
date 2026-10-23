import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// The focusing click selects the whole address on every macOS (report
/// 2026-10-20, "highlighting stuff in omnibar in sequoia is broken").
///
/// The field grows to the left when it takes focus, while the button is
/// still down. On macOS 15 AppKit's text tracking maps the press in the old
/// layout and the release in the new one, so a click that never moved ends
/// with a few characters selected (`[5, 13]` in a Tart VM) where
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

    /// A focusing press that dragged past the threshold keeps its selection.
    @Test func aFocusingDragKeepsWhatItSelected() throws {
        let rest = try page()
        let focused = reduce(rest, [.fieldMouseDown(clickCount: 1), .focusGained(.mouse)])
        let dragged = reduce(focused, [
            .fieldMouseDragged,
            .fieldChanged(.init(text: focused.fieldText, selection: NSRange(location: 5, length: 8)), nil),
            .fieldMouseUp,
        ])
        #expect(dragged.edit.selection == NSRange(location: 5, length: 8))
    }

    private func mouse(_ type: NSEvent.EventType, x: CGFloat, window: Int = 7) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 10), modifierFlags: [], timestamp: 0,
                                        windowNumber: window, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// The release decides the drag, in window points, past 5 pt.
    @Test func theReleaseDecidesTheDrag() throws {
        let press = try mouse(.leftMouseDown, x: 100)
        #expect(!press.omnibarDragged(to: try mouse(.leftMouseUp, x: 100)))
        #expect(!press.omnibarDragged(to: try mouse(.leftMouseUp, x: 104)))
        #expect(press.omnibarDragged(to: try mouse(.leftMouseUp, x: 112)))
        #expect(!press.omnibarDragged(to: try mouse(.leftMouseUp, x: 112, window: 8)))
        #expect(!press.omnibarDragged(to: nil))
    }
}
