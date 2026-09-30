import Foundation
import Testing
@testable import CmuxNextBrowser

/// Keyboard sequences through the omnibar state machine and the real
/// effect applier (fake field). Every step also checks the invariants.
@MainActor
@Suite struct OmnibarKeyboardTests {
    private func range(_ location: Int, _ length: Int) -> NSRange { NSRange(location: location, length: length) }
    let pageText = "https://github.com/manaflow-ai/cmux"

    @Test func focusShowsTheFullURLAllSelectedAndEnterReloadsIt() {
        let sim = OmnibarSim()
        #expect(sim.field.text == "github.com/manaflow-ai/cmux")
        #expect(sim.field.style == .compactURL(OmnibarSim.page))
        sim.focus()
        #expect(sim.state.phase == .focused)
        #expect(sim.field.text == pageText)
        #expect(sim.field.selection == range(0, 35))
        #expect(sim.effects == [.began])
        sim.key(.enter(.currentTab))
        #expect(sim.ended == [.commit(OmnibarSim.page)])
        #expect(sim.state.phase == .committing(display: OmnibarSim.page))
    }

    /// The #15796 regression: each suggestion round trip must leave the
    /// caret at the end, or "google.com" comes out reversed.
    @Test func typingWithSuggestionsBetweenKeysKeepsTheCaretAtTheEnd() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("google.com")
        #expect(sim.field.text == "google.com")
        #expect(sim.field.selection == range(10, 0))
        #expect(sim.state.edit.userText == "google.com")
        #expect(sim.popup.rows.first?.title == "google.com")
    }

    @Test func typingFasterThanSuggestionsKeepsTheCaretAtTheEnd() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("google.com", settle: false)
        sim.answer()
        #expect(sim.field.text == "google.com")
        #expect(sim.field.selection == range(10, 0))
    }

    @Test func inlineCompletionIsASelectedSuffixAndBackspaceRemovesIt() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("gi")
        #expect(sim.field.text == "github.com")
        #expect(sim.field.selection == range(2, 8))
        // Typing on replaces the completion and the rest stays shown at once.
        sim.type("t", settle: false)
        #expect(sim.field.text == "github.com")
        #expect(sim.field.selection == range(3, 7))
        sim.answer()
        #expect(sim.field.selection == range(3, 7))
        sim.backspace()
        #expect(sim.field.text == "git")
        #expect(sim.field.selection == range(3, 0))
        sim.answer()
        #expect(sim.field.text == "git", "Backspace never re-adds the completion")
    }

    /// Seen live: typing the last character of a shown completion leaves the
    /// text unchanged, and the card kept rows for the previous text.
    @Test func typingTheLastCompletedCharacterRequeries() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("google.co")
        sim.historyURLs = ["https://google.com/"]
        sim.backspace()
        sim.type("o")
        #expect(sim.field.text == "google.com")
        #expect(sim.field.selection == range(9, 1))
        sim.type("m", settle: false)
        #expect(sim.state.edit.userText == "google.com")
        #expect(sim.state.edit.inlineCompletion.isEmpty)
        #expect(sim.queries.last?.text == "google.com")
        sim.answer()
        #expect(sim.popup.rows.first?.title == "google.com")
        #expect(!sim.popup.rows.contains { $0.title == "google.co" })
    }

    @Test func typingInTheMiddleNeverCompletes() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("gthub.com")
        sim.moveSelection(to: range(1, 0))
        sim.type("i")
        #expect(sim.field.text == "github.com")
        #expect(sim.field.selection == range(2, 0))
    }

    @Test func rightArrowOrAnyCaretMoveAcceptsTheCompletion() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("gi")
        sim.moveSelection(to: range(10, 0)) // Right arrow collapses to the end
        #expect(sim.state.edit.userText == "github.com")
        #expect(sim.state.edit.inlineCompletion.isEmpty)
        #expect(sim.field.selection == range(10, 0))
    }

    @Test func arrowsShowRowTextClampAndReturnToTyped() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("docs")
        #expect(sim.popup.rows.count == 2)
        #expect(sim.popup.highlightedRows == [0])
        #expect(sim.key(.down))
        #expect(sim.field.text == "https://example.com/docs")
        #expect(sim.field.selection == range(24, 0))
        #expect(sim.key(.down)) // clamps
        #expect(sim.popup.highlightedRows == [1])
        #expect(sim.key(.up))
        #expect(sim.field.text == "docs")
        #expect(sim.key(.up)) // clamps
        #expect(sim.state.popup.selected == 0)
    }

    @Test func arrowsWithoutACardAreTheFieldsOwn() {
        let sim = OmnibarSim()
        sim.focus()
        #expect(!sim.key(.down))
        #expect(!sim.key(.up))
    }

    @Test func tabMovesThroughRowsAndLeavesPastTheEnds() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("docs")
        #expect(sim.key(.tab))
        #expect(sim.state.popup.selected == 1)
        #expect(!sim.key(.tab), "Tab past the last row moves focus out")
        #expect(sim.key(.backTab))
        #expect(!sim.key(.backTab), "Shift-Tab past the first row moves focus out")
    }

    @Test func enterCommitsTheArrowedRow() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("docs")
        sim.key(.down)
        sim.key(.enter(.currentTab))
        #expect(sim.ended == [.commit(URL(string: "https://example.com/docs")!)])
        #expect(sim.popup.rows.isEmpty)
        #expect(sim.field.text == "example.com/docs")
    }

    @Test func enterWithModifiersOpensElsewhereAndKeepsThePage() {
        for (disposition, expected) in [
            (OmnibarInput.Disposition.newBackgroundTab, OmnibarInput.Disposition.newBackgroundTab),
            (.newForegroundTab, .newForegroundTab),
            (.newWindow, .newWindow),
        ] {
            let sim = OmnibarSim()
            sim.focus()
            sim.type("cmux.dev")
            sim.key(.enter(disposition))
            #expect(sim.ended == [.open(URL(string: "https://cmux.dev")!, expected)])
            #expect(sim.state.pageURL == OmnibarSim.page)
            #expect(sim.field.text == "github.com/manaflow-ai/cmux")
        }
    }

    @Test func enterOnStaleRowsResolvesWhatWasTyped() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("gi")
        sim.backspace() // completion gone
        sim.type("x", settle: false) // "gix": rows are still those for "gi"
        sim.key(.enter(.currentTab))
        guard case .commit(let url) = sim.ended.last else { Issue.record("no commit"); return }
        #expect(url.host() == "www.google.com")
    }

    @Test func escapeRevertsThenCancelsAndUndoBringsTheTextBack() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("hello")
        #expect(sim.key(.escape)) // closes the card
        #expect(sim.popup.rows.isEmpty)
        #expect(sim.key(.escape))
        #expect(sim.state.phase == .focused)
        #expect(sim.field.text == "github.com/manaflow-ai/cmux")
        #expect(sim.field.selection == range(0, 27))
        #expect(sim.key(.undo))
        #expect(sim.field.text == "hello")
        #expect(sim.key(.escape)) // reverts (the card is closed)
        #expect(sim.key(.escape))
        #expect(sim.ended == [.cancel])
        #expect(sim.state.phase == .idle)
    }

    @Test func undoAndRedoWalkTypingRuns() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("abc")
        sim.backspace()
        sim.backspace()
        #expect(sim.field.text == "a")
        sim.key(.undo) // the deletion run
        #expect(sim.field.text == "abc")
        sim.key(.undo) // the typing run: back to the untouched URL
        #expect(sim.state.phase == .focused)
        #expect(sim.field.text == pageText)
        sim.key(.redo)
        #expect(sim.field.text == "abc")
        sim.key(.redo)
        #expect(sim.field.text == "a")
        #expect(sim.key(.redo), "nothing left to redo is still swallowed")
    }

    @Test func selectAllAcceptsTheCompletionAndSelectsEverything() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("gi")
        sim.key(.selectAll)
        #expect(sim.state.edit.userText == "github.com")
        #expect(sim.field.selection == range(0, 10))
    }

    @Test func pasteBecomesOneLineAndPasteAndGoCommits() {
        let sim = OmnibarSim()
        sim.focus()
        sim.paste("cmux\nterminal")
        #expect(sim.field.text == "cmux terminal")
        sim.send(.pasteAndGo("  example.com/a\n"))
        #expect(sim.ended == [.commit(URL(string: "https://example.com/a")!)])
        sim.send(.pasteAndGo("   "))
        #expect(sim.effects.last == .beep)
    }

    @Test func keysWithoutFocusAreNotTaken() {
        let sim = OmnibarSim()
        for key: OmnibarInput.Key in [.up, .down, .tab, .enter(.currentTab), .escape, .selectAll, .undo] {
            #expect(!sim.key(key))
        }
    }

    @Test func typingAfterACommitBeforeFocusLeavesStartsEditingAgain() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("cmux.dev")
        sim.key(.enter(.currentTab))
        #expect(sim.state.phase == .committing(display: URL(string: "https://cmux.dev")!))
        sim.field.selection = NSRange(location: (sim.field.text as NSString).length, length: 0)
        sim.type("x")
        #expect(sim.state.phase == .editing)
        #expect(sim.effects.filter { $0 == .began }.count == 2)
    }

    @Test func blankTextClosesTheCard() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("a")
        #expect(!sim.popup.rows.isEmpty)
        sim.backspace()
        #expect(sim.popup.rows.isEmpty)
        #expect(sim.state.popup.selected == nil)
    }
}
