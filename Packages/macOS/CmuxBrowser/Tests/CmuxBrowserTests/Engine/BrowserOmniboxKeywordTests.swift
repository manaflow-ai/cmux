import Foundation
import Testing
@testable import CmuxBrowser

/// chrome.omnibox keyword sessions in a Chromium panel's address bar.
@Suite
struct BrowserOmniboxKeywordTests {
    private let notes = BrowserOmniboxKeyword(extensionID: "abc", keyword: "nt", name: "Notes",
                                              defaultDescription: "Search notes for %s")
    private let plain = BrowserOmniboxKeyword(extensionID: "def", keyword: "gh", name: "GitHub")

    @Test
    func keywordAndSpaceStartTheSession() throws {
        let match = try #require(BrowserOmniboxKeyword.match("NT hello world", in: [plain, notes]))
        #expect(match.keyword == notes)
        #expect(match.rest == "hello world")
        #expect(BrowserOmniboxKeyword.match("nt ", in: [notes])?.rest == "")
        #expect(BrowserOmniboxKeyword.match("  gh x", in: [plain])?.rest == "x")
    }

    @Test
    func textWithoutKeywordAndSpaceIsNoSession() {
        #expect(BrowserOmniboxKeyword.match("nt", in: [notes]) == nil)
        #expect(BrowserOmniboxKeyword.match("ntx hello", in: [notes]) == nil)
        #expect(BrowserOmniboxKeyword.match("example.com", in: [notes, plain]) == nil)
        #expect(BrowserOmniboxKeyword.match("nt hello", in: []) == nil)
    }

    @Test
    func defaultRowComesFirstThenTheExtensionsRowsWithoutRepeats() {
        let rows = notes.rows(text: "milk", suggestions: [
            BrowserOmniboxKeywordSuggestion(extensionID: "abc", content: "milk", description: "dup"),
            BrowserOmniboxKeywordSuggestion(extensionID: "abc", content: "milk tea", description: "Milk tea"),
            BrowserOmniboxKeywordSuggestion(extensionID: "abc", content: "", description: "empty"),
        ])
        #expect(rows.map(\.content) == ["milk", "milk tea"])
        #expect(rows.first?.description == "Search notes for milk")
        #expect(plain.defaultSuggestion(for: "x").description == "GitHub: x")
        #expect(notes.rows(text: "", suggestions: []).isEmpty)
    }

    @Test
    func sessionStartsOnceAndCancelsWhenTheKeywordGoes() {
        var session = BrowserOmniboxKeywordSessionState()
        #expect(session.update("abc") == [.started("abc")])
        #expect(session.update("abc") == [])
        #expect(session.update("def") == [.cancelled("abc"), .started("def")])
        #expect(session.update(nil) == [.cancelled("def")])
        #expect(session.update(nil) == [])
    }

    @Test
    func enteredSessionIsNotCancelledAfterwards() {
        var session = BrowserOmniboxKeywordSessionState()
        _ = session.update("abc")
        session.entered()
        #expect(session.activeExtensionID == nil)
        #expect(session.update(nil) == [])
    }
}
