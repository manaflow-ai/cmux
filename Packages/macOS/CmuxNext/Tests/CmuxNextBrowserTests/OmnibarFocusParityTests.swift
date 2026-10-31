import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Focus rules of Chromium's omnibox that the first parity pass left open
/// (docs/omnibar-chromium-parity.md, Lawrence 2026-10-30).
@MainActor
struct OmnibarFocusParityTests {
    private var resolver: OmniboxResolver {
        var resolver = OmniboxResolver()
        resolver.keywords = OmnibarKeyword.searchEngines(default: resolver.searchEngine)
        return resolver
    }

    private func reduce(_ inputs: [OmnibarInput]) -> (OmnibarState, [OmnibarEffect]) {
        reduce(OmnibarState(), inputs)
    }

    private func reduce(_ state: OmnibarState, _ inputs: [OmnibarInput]) -> (OmnibarState, [OmnibarEffect]) {
        var state = state
        var effects: [OmnibarEffect] = []
        for input in inputs {
            let step = OmnibarReducer.reduce(state, input, resolver: resolver)
            state = step.state
            effects += step.effects
        }
        return (state, effects)
    }

    private func typed(_ text: String, from start: String = "", focus: Bool = true) -> [OmnibarInput] {
        var inputs: [OmnibarInput] = focus ? [.focusGained(.keyboard)] : []
        var current = start
        for character in text {
            current.append(character)
            inputs.append(.fieldChanged(.init(text: current, selection: NSRange(location: current.utf16.count, length: 0)), .insert))
        }
        return inputs
    }

    // MARK: Cmd-L in keyword mode

    /// Chromium `OmniboxViewViews::SetFocus(true)` on an omnibox that already
    /// has focus calls `OmniboxEditModel::ClearKeyword`: Cmd-L leaves "Search
    /// YouTube", puts the keyword back in front of the typed text, and
    /// selects all of it.
    @Test func cmdLLeavesKeywordModeAndSelectsAll() {
        let (session, _) = reduce(typed("youtube.com") + [.key(.tab)] + typed("lofi", focus: false))
        #expect(session.keyword?.searchEngine?.id == "youtube")
        let (state, _) = reduce(session, [.key(.focusLocation)])
        #expect(state.keyword == nil)
        #expect(state.fieldText == "youtube.com lofi")
        #expect(state.edit.selection == NSRange(location: 0, length: ("youtube.com lofi" as NSString).length))
        #expect(OmnibarPresentation(state).chip != .engineKeyword(label: "Search YouTube"))
    }

    // MARK: Leaving keyword mode (OmniboxEditModel::ClearKeyword)

    /// Tab straight after the keyword, nothing typed (Chromium's state 4):
    /// Backspace gives back the keyword alone, caret after it.
    @Test func backspaceRightAfterTabGivesTheKeywordBack() {
        let (state, _) = reduce(typed("youtube.com") + [.key(.tab), .key(.backspaceAtStart)])
        #expect(state.keyword == nil)
        #expect(state.edit.userText == "youtube.com")
        #expect(state.edit.selection == NSRange(location: 11, length: 0))
    }

    /// Text typed in the session (state 1): the keyword and a space come
    /// back in front of it, so typing on does not start the session again.
    @Test func backspaceAfterTypingKeepsASpaceAfterTheKeyword() {
        let (session, _) = reduce(typed("youtube.com") + [.key(.tab)] + typed("lofi", focus: false))
        let (state, _) = reduce(session, [.fieldChanged(.init(text: "lofi", selection: NSRange(location: 0, length: 0)), nil),
                                          .key(.backspaceAtStart)])
        #expect(state.keyword == nil)
        #expect(state.edit.userText == "youtube.com lofi")
        #expect(state.edit.selection == NSRange(location: 12, length: 0))
    }

    /// A space started the session (state 3): the space stays.
    @Test func backspaceAfterASpaceEntryKeepsTheSpace() {
        let (state, _) = reduce(typed("github.com ") + [.key(.backspaceAtStart)])
        #expect(state.keyword == nil)
        #expect(state.edit.userText == "github.com ")
        #expect(state.edit.selection == NSRange(location: 11, length: 0))
    }

    /// Opt-Cmd-F (a keyboard shortcut entry): no keyword comes back.
    @Test func backspaceAfterSearchTheWebRestoresNoKeyword() {
        let (session, _) = reduce([.focusGained(.keyboard), .key(.searchWithDefaultEngine)] + typed("cats", focus: false))
        let (state, _) = reduce(session, [.fieldChanged(.init(text: "cats", selection: NSRange(location: 0, length: 0)), nil),
                                          .key(.backspaceAtStart)])
        #expect(state.keyword == nil)
        #expect(state.edit.userText == "cats")
        #expect(state.edit.selection == NSRange(location: 0, length: 0))
    }
}
