import Foundation
import Testing
@testable import CmuxNextBrowser

/// Extension keyword sessions (`chrome.omnibox`) in the omnibar reducer:
/// the keyword and a space start a session, the extension gets every change,
/// Enter hands it the text, Backspace at the start, Escape and blur end it.
@Suite struct OmnibarKeywordTests {
    static let keyword = OmnibarKeyword(extensionID: "ext-1", keyword: "kw", name: "Keyword Ext")

    struct Drive {
        var state = OmnibarState(pageURL: URL(string: "https://example.com/page")!)
        var resolver = OmniboxResolver(keywords: [OmnibarKeywordTests.keyword])
        var effects: [OmnibarEffect] = []

        @discardableResult
        mutating func send(_ input: OmnibarInput) -> Bool {
            let transition = OmnibarReducer.reduce(state, input, resolver: resolver)
            state = transition.state
            effects += transition.effects
            return transition.handled
        }

        /// Focus, then one inserted character at a time with the caret at the end.
        mutating func type(_ text: String) {
            if !state.hasFocus { send(.focusGained(.keyboard)) }
            for character in text {
                let current = state.phase == .focused ? "" : state.edit.userText
                let next = current + String(character)
                send(.fieldChanged(.init(text: next, selection: NSRange(location: (next as NSString).length, length: 0)), .insert))
            }
        }

        var inputs: [String] {
            effects.compactMap { if case .keywordInput(_, let text, _) = $0 { text } else { nil } }
        }
    }

    @Test func keywordAndSpaceStartASession() {
        var drive = Drive()
        drive.type("kw ")
        #expect(drive.state.keyword == Self.keyword)
        #expect(drive.state.fieldText == "")
        #expect(drive.effects.contains(.keywordStarted(extensionID: "ext-1")))
        #expect(OmnibarPresentation(drive.state).chip == .keyword(name: "Keyword Ext"))
    }

    @Test func keywordWithoutSpaceIsPlainText() {
        var drive = Drive()
        drive.type("kwx")
        #expect(drive.state.keyword == nil)
        #expect(drive.state.fieldText == "kwx")
        drive.type(" y")
        #expect(drive.state.keyword == nil, "only the keyword itself followed by a space starts a session")
    }

    @Test func everyChangeGoesToTheExtension() {
        var drive = Drive()
        drive.type("kw abc")
        #expect(drive.state.fieldText == "abc")
        #expect(drive.inputs == ["", "a", "ab", "abc"])
        let start = drive.effects.firstIndex(of: .keywordStarted(extensionID: "ext-1")) ?? 0
        #expect(!drive.effects[start...].contains { if case .query = $0 { true } else { false } }, "no URL suggestions in a session")
    }

    @Test func enterHandsTheTextToTheExtension() {
        var drive = Drive()
        drive.type("kw hello")
        drive.send(.key(.enter(.currentTab)))
        #expect(drive.effects.last == .ended(.keyword(extensionID: "ext-1", text: "hello", disposition: .currentTab)))
        #expect(drive.state.keyword == nil)
        #expect(drive.state.pageURL == URL(string: "https://example.com/page"), "the extension decides what loads")
    }

    @Test func anArrowedRowSendsItsContent() {
        var drive = Drive()
        drive.type("kw he")
        let generation = drive.state.generation
        let rows = CEFOmniboxKeywords.rows(json: #"[{"content":"hello world","description":"Hello"}]"#, keyword: Self.keyword, text: "he")
        drive.send(.suggestions(generation: generation, rows: rows))
        #expect(drive.state.isPopupOpen)
        drive.send(.key(.down))
        #expect(drive.state.fieldText == "hello world")
        drive.send(.key(.enter(.newBackgroundTab)))
        #expect(drive.effects.last == .ended(.keyword(extensionID: "ext-1", text: "hello world", disposition: .newBackgroundTab)))
    }

    @Test func rowClickSendsItsContent() {
        var drive = Drive()
        drive.type("kw he")
        let rows = CEFOmniboxKeywords.rows(json: #"[{"content":"help","description":"Help"}]"#, keyword: Self.keyword, text: "he")
        drive.send(.suggestions(generation: drive.state.generation, rows: rows))
        drive.send(.rowClick(row: 1, .currentTab))
        #expect(drive.effects.last == .ended(.keyword(extensionID: "ext-1", text: "help", disposition: .currentTab)))
    }

    @Test func backspaceAtTheStartLeavesTheSessionAndKeepsTheKeyword() {
        var drive = Drive()
        drive.type("kw ")
        let handled = drive.send(.key(.backspaceAtStart))
        #expect(handled)
        #expect(drive.state.keyword == nil)
        #expect(drive.state.fieldText == "kw")
        #expect(drive.effects.contains(.keywordEnded(extensionID: "ext-1")))
    }

    @Test func backspaceElsewhereIsTheFieldEditors() {
        var drive = Drive()
        drive.type("kw ab")
        let atEnd = drive.send(.key(.backspaceAtStart))
        #expect(!atEnd, "caret at the end: a normal deletion")
        var plain = Drive()
        plain.type("abc")
        let handled = plain.send(.key(.backspaceAtStart))
        #expect(!handled)
    }

    @Test func escapeLeavesTheSessionAndReverts() {
        var drive = Drive()
        drive.type("kw ab")
        drive.send(.key(.escape))
        #expect(drive.state.keyword == nil)
        #expect(drive.effects.contains(.keywordEnded(extensionID: "ext-1")))
        #expect(drive.state.phase == .focused)
        #expect(drive.state.fieldText == "example.com/page", "back to the page URL, as Escape does outside a session")
    }

    @Test func blurEndsTheSession() {
        var drive = Drive()
        drive.type("kw ab")
        drive.send(.focusLost)
        #expect(drive.state.keyword == nil)
        #expect(drive.state.retainedText == nil, "the text means nothing without its keyword")
        #expect(drive.effects.contains(.keywordEnded(extensionID: "ext-1")))
    }

    @Test func tabAfterTheExactKeywordStartsASession() {
        var drive = Drive()
        drive.type("KW")
        let handled = drive.send(.key(.tab))
        #expect(handled)
        #expect(drive.state.keyword == Self.keyword, "keywords compare without case")
        #expect(drive.state.fieldText == "")
    }

    @Test func tabWithoutAKeywordMovesFocus() {
        var drive = Drive()
        drive.type("abc")
        let handled = drive.send(.key(.tab))
        #expect(!handled)
        #expect(drive.state.keyword == nil)
    }

    @Test func noKeywordsNoSessions() {
        var drive = Drive()
        drive.resolver.keywords = []
        drive.type("kw ab")
        #expect(drive.state.keyword == nil)
        #expect(drive.state.fieldText == "kw ab")
    }

    @Test func suggestionRowsKeepTheExtensionOrderAfterTheDefaultRow() {
        let keyword = OmnibarKeyword(extensionID: "e", keyword: "k", name: "Ext", defaultDescription: "Search Ext for %s")
        let rows = CEFOmniboxKeywords.rows(json: #"[{"content":"b","description":"B"},{"content":"a"},{"content":"q"}]"#, keyword: keyword, text: "q")
        #expect(rows.map(\.content) == ["q", "b", "a"])
        #expect(rows[0].title == "Search Ext for q")
        #expect(rows.allSatisfy { $0.kind == .keyword })
        #expect(OmnibarRules.inlineCompletion(for: rows[1], typed: "b") == nil, "keyword rows never complete inline")
    }

    @Test func keywordListDecodes() {
        let json = #"[{"extension_id":"a","keyword":"gh","name":"GitHub","default_description":"Go to %s"},{"extension_id":"","keyword":"x"}]"#
        #expect(CEFOmniboxKeywords.keywords(json: json) == [OmnibarKeyword(extensionID: "a", keyword: "gh", name: "GitHub", defaultDescription: "Go to %s")])
        #expect(CEFOmniboxKeywords.keywords(json: "nope").isEmpty)
    }
}
