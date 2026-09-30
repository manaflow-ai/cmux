import Foundation
import Testing
@testable import CmuxNextBrowser

/// The omnibar's editing rules (`OmniboxEditModel`): select-all on focus,
/// inline autocomplete, arrow keys, Escape revert then cancel, Enter commit.
@Suite struct OmniboxEditModelTests {
    let resolver = OmniboxResolver()
    let page = URL(string: "https://github.com/manaflow-ai/cmux")!

    private func history(_ url: String, title: String = "Page") -> BrowserSuggestion {
        BrowserSuggestion(kind: .history, title: title, detail: url, url: URL(string: url)!, score: 700)
    }

    private func typed(_ text: String) -> BrowserSuggestion {
        OmniboxSuggestionEngine(resolver: resolver).primarySuggestion(for: text)!
    }

    private func range(_ location: Int, _ length: Int) -> NSRange { NSRange(location: location, length: length) }

    @Test func focusShowsTheFullURLAllSelected() {
        var model = OmniboxEditModel()
        model.begin(url: page)
        let text = "https://github.com/manaflow-ai/cmux"
        #expect(model.isEditing)
        #expect(model.presentation == .init(text: text, selection: range(0, text.utf16.count)))
        // Enter without typing reloads the page URL.
        #expect(model.commitDestination(resolver: resolver) == page)
    }

    @Test func blankPageFocusesEmpty() {
        var model = OmniboxEditModel()
        model.begin(url: URL(string: "about:blank"))
        #expect(model.presentation.text.isEmpty)
        #expect(model.commitDestination(resolver: resolver) == nil)
    }

    @Test func historyRowCompletesInlineAndBecomesTheDefault() {
        var model = OmniboxEditModel()
        model.begin(url: page)
        model.userEdited("git", isDeletion: false)
        let rows = [typed("git"), history("https://github.com/")]
        let changed = model.received(rows, for: "git")
        #expect(changed)
        #expect(model.inlineCompletion == "hub.com")
        #expect(model.presentation == .init(text: "github.com", selection: range(3, 7)))
        #expect(model.suggestions.first?.url.absoluteString == "https://github.com/")
        #expect(model.commitDestination(resolver: resolver)?.absoluteString == "https://github.com/")
    }

    @Test func deletingNeverCompletes() {
        var model = OmniboxEditModel()
        model.begin(url: page)
        model.userEdited("git", isDeletion: true)
        model.received([typed("git"), history("https://github.com/")], for: "git")
        #expect(model.inlineCompletion.isEmpty)
        #expect(model.presentation == .init(text: "git", selection: range(3, 0)))
        // "git" alone is a search.
        #expect(model.commitDestination(resolver: resolver)?.host() == "www.google.com")
    }

    @Test func staleResultsAreDropped() {
        var model = OmniboxEditModel()
        model.begin(url: page)
        model.userEdited("gi", isDeletion: false)
        model.userEdited("gith", isDeletion: false)
        let changed = model.received([history("https://github.com/")], for: "gi")
        #expect(!changed)
        #expect(model.suggestions.isEmpty)
    }

    @Test func completionNeedsAPrefixOfTheShownURL() {
        let row = history("https://www.example.com/docs")
        #expect(OmniboxEditModel.inlineCompletion(for: row, typed: "exa") == "mple.com/docs")
        #expect(OmniboxEditModel.inlineCompletion(for: row, typed: "https://www.ex") == "ample.com/docs")
        #expect(OmniboxEditModel.inlineCompletion(for: row, typed: "docs") == nil)
        #expect(OmniboxEditModel.inlineCompletion(for: row, typed: "exa ") == nil)
        #expect(OmniboxEditModel.inlineCompletion(for: row, typed: "example.com/docs") == nil)
        let search = BrowserSuggestion(kind: .search, title: "example", detail: "", url: URL(string: "https://s.test/?q=example")!, score: 1)
        #expect(OmniboxEditModel.inlineCompletion(for: search, typed: "exa") == nil)
    }

    @Test func arrowsShowRowTextAndReturnToTyped() {
        var model = OmniboxEditModel()
        model.begin(url: page)
        model.userEdited("cmux docs", isDeletion: false)
        let rows = [typed("cmux docs"), history("https://cmux.com/docs", title: "Docs")]
        model.received(rows, for: "cmux docs")
        #expect(model.selectedIndex == 0)
        model.move(1)
        #expect(model.presentation.text == "https://cmux.com/docs")
        model.move(1) // clamps at the last row
        #expect(model.selectedIndex == 1)
        #expect(model.commitDestination(resolver: resolver)?.absoluteString == "https://cmux.com/docs")
        model.move(-1)
        #expect(model.presentation == .init(text: "cmux docs", selection: range(9, 0)))
        model.move(-1) // clamps at the first row
        #expect(model.selectedIndex == 0)
    }

    @Test func escapeRevertsThenCancels() {
        var model = OmniboxEditModel()
        model.begin(url: page)
        model.userEdited("hello", isDeletion: false)
        model.received([typed("hello")], for: "hello")
        let first = model.escape()
        #expect(first == .reverted)
        #expect(!model.isPopupOpen)
        let text = "https://github.com/manaflow-ai/cmux"
        #expect(model.presentation == .init(text: text, selection: range(0, text.utf16.count)))
        let second = model.escape()
        #expect(second == .cancel)
    }

    @Test func untouchedTextFollowsThePage() {
        var model = OmniboxEditModel()
        model.begin(url: page)
        model.pageURLChanged(URL(string: "https://github.com/manaflow-ai/cmux/pulls"))
        #expect(model.presentation.text == "https://github.com/manaflow-ai/cmux/pulls")
    }

    @Test func clearingTheTextClosesThePopup() {
        var model = OmniboxEditModel()
        model.begin(url: page)
        model.userEdited("a", isDeletion: false)
        model.received([typed("a")], for: "a")
        model.userEdited("", isDeletion: true)
        #expect(!model.isPopupOpen)
        #expect(model.selectedIndex == nil)
    }

    @Test func hostRangeCoversTheShownHost() {
        let url = URL(string: "https://www.example.com/a/b?c=1")!
        let text = BrowserURLDisplay.displayText(for: url)
        #expect(text == "example.com/a/b?c=1")
        #expect(BrowserURLDisplay.hostRange(in: text, for: url) == range(0, 11))
        let insecure = URL(string: "http://localhost:3000/x")!
        let shown = BrowserURLDisplay.displayText(for: insecure)
        #expect(BrowserURLDisplay.hostRange(in: shown, for: insecure) == range(7, 9))
        #expect(BrowserURLDisplay.hostRange(in: "/tmp/a", for: URL(filePath: "/tmp/a")) == nil)
    }
}
