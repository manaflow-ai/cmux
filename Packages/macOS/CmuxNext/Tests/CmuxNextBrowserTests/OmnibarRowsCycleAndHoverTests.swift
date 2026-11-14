import AppKit
@testable import CmuxNextBrowser
import CmuxNextBrowserCore
import Foundation
import Testing

/// The omnibar's suggestion rows (Lucas 2026-11-14): Up and Down cycle through them endlessly, as Chrome's do, and a
/// row the pointer leaves keeps its highlight until the next row takes it, so moving between rows never flashes the
/// keyboard's row.
@MainActor
struct OmnibarRowsCycleAndHoverTests {
    private let resolver = OmniboxResolver()

    private func reduce(_ inputs: [OmnibarInput], from state: OmnibarState) -> OmnibarState {
        inputs.reduce(state) { OmnibarReducer.reduce($0, $1, resolver: resolver).state }
    }

    /// An open card of three rows, the first highlighted by the keyboard.
    private func openCard() -> OmnibarState {
        var state = reduce([.focusGained(.keyboard), .fieldChanged(.init(text: "ab", selection: NSRange(location: 2, length: 0)), .insert)],
                           from: OmnibarState())
        state.popup.rows = (0..<3).map {
            BrowserSuggestion(kind: .search, title: "ab \($0)", detail: "", url: URL(string: "https://example.com/\($0)")!, score: 1)
        }
        state.popup.selected = 0
        state.popup.hover = nil
        state.popup.source = .keyboard
        return state
    }

    @Test func upFromTheFirstRowGoesToTheLast() {
        let state = openCard()
        #expect(state.isPopupOpen)
        #expect(reduce([.key(.up)], from: state).popup.highlighted == 2)
    }

    @Test func downFromTheLastRowGoesToTheFirst() {
        let state = reduce([.key(.down), .key(.down), .key(.down)], from: openCard())
        #expect(state.popup.highlighted == 0)
    }

    @Test func leavingARowKeepsItsHighlight() {
        let first = CGPoint(x: 1, y: 1), second = CGPoint(x: 2, y: 2), third = CGPoint(x: 3, y: 3)
        // The first pointer report only records where the pointer rests; hover starts once it moves.
        let hovered = reduce([.rowHover(row: 2, pointer: first), .rowHover(row: 2, pointer: second)], from: openCard())
        #expect(hovered.popup.highlighted == 2)
        let left = reduce([.rowHover(row: nil, pointer: third)], from: hovered)
        #expect(left.popup.highlighted == 2, "the row the pointer left keeps its highlight, not the keyboard's row 0")
    }
}
