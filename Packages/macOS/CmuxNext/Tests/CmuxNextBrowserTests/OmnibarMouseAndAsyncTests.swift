import Foundation
import Testing
@testable import CmuxNextBrowser

/// Mouse sequences (field clicks, row hover and clicks, and their conflicts
/// with the keyboard highlight), async suggestions, IME composition, page
/// navigation during editing, focus loss and the search engine switch.
@MainActor
@Suite struct OmnibarMouseAndAsyncTests {
    private func range(_ location: Int, _ length: Int) -> NSRange { NSRange(location: location, length: length) }
    let pageText = "https://github.com/manaflow-ai/cmux"

    // MARK: Field clicks

    @Test func theFocusingClickSelectsEverything() {
        let sim = OmnibarSim()
        sim.click(selecting: range(7, 0))
        #expect(sim.field.selection == range(0, 35))
        #expect(sim.state.focusingClick == nil)
    }

    @Test func aFocusingDragKeepsItsSelection() {
        let sim = OmnibarSim()
        sim.click(selecting: range(8, 10))
        #expect(sim.field.selection == range(8, 10))
    }

    @Test func laterClicksPlaceTheCaretAndDoubleAndTripleClicksSelect() {
        let sim = OmnibarSim()
        sim.click(selecting: range(3, 0))
        sim.click(selecting: range(12, 0))
        #expect(sim.field.selection == range(12, 0), "second click places the caret")
        sim.click(count: 2, selecting: range(8, 6))
        #expect(sim.field.selection == range(8, 6), "double-click keeps the word")
        sim.click(count: 3, selecting: range(0, 35))
        #expect(sim.field.selection == range(0, 35), "triple-click selects all")
    }

    @Test func clickingOutsideKeepsTypedTextLikeChromeAndRefocusSelectsIt() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("half typed")
        sim.blur()
        #expect(sim.ended == [.blur])
        #expect(sim.popup.rows.isEmpty)
        #expect(sim.field.text == "half typed")
        #expect(sim.field.style == .plain)
        sim.click(selecting: range(4, 0))
        #expect(sim.state.phase == .editing)
        #expect(sim.field.text == "half typed")
        #expect(sim.field.selection == range(0, 10))
        // A navigation replaces text left behind by an earlier blur.
        sim.blur()
        sim.send(.pageURLChanged(URL(string: "https://example.com/next")!))
        #expect(sim.field.text == "example.com/next")
    }

    // MARK: Rows

    private func simWithRows() -> OmnibarSim {
        let sim = OmnibarSim()
        sim.historyURLs = ["https://a.test/github", "https://b.test/github", "https://c.test/github"]
        sim.focus()
        sim.type("github")
        #expect(sim.popup.rows.count == 4)
        return sim
    }

    @Test func aCardOpeningUnderARestingPointerDoesNotStealTheHighlight() {
        let sim = simWithRows()
        sim.send(.rowHover(row: 2, pointer: CGPoint(x: 10, y: 10)))
        #expect(sim.popup.highlightedRows == [0], "no movement yet")
        sim.send(.rowHover(row: 2, pointer: CGPoint(x: 10, y: 10)))
        #expect(sim.popup.highlightedRows == [0], "same location is not movement")
        sim.send(.rowHover(row: 2, pointer: CGPoint(x: 11, y: 10)))
        #expect(sim.popup.highlightedRows == [2])
        #expect(sim.field.text == "github", "hover never changes the text")
    }

    @Test func keyboardTakesTheHighlightBackUntilThePointerMovesAgain() {
        let sim = simWithRows()
        sim.send(.rowHover(row: 3, pointer: CGPoint(x: 1, y: 1)))
        sim.send(.rowHover(row: 3, pointer: CGPoint(x: 2, y: 1)))
        #expect(sim.popup.highlightedRows == [3])
        sim.key(.down)
        #expect(sim.popup.highlightedRows == [1], "keyboard moves from its own selection")
        #expect(sim.field.text == "https://a.test/github")
        sim.send(.rowHover(row: 3, pointer: CGPoint(x: 2, y: 1)))
        #expect(sim.popup.highlightedRows == [1], "a resting pointer does not take it back")
        sim.send(.rowHover(row: 2, pointer: CGPoint(x: 2, y: 9)))
        #expect(sim.popup.highlightedRows == [2])
        #expect(sim.field.text == "https://a.test/github")
        sim.key(.enter(.currentTab))
        #expect(sim.ended == [.commit(URL(string: "https://a.test/github")!)], "Enter commits what the field shows")
    }

    @Test func leavingTheRowsFallsBackToTheKeyboardHighlight() {
        let sim = simWithRows()
        sim.send(.rowHover(row: 3, pointer: CGPoint(x: 1, y: 1)))
        sim.send(.rowHover(row: 3, pointer: CGPoint(x: 1, y: 2)))
        sim.send(.rowHover(row: nil, pointer: CGPoint(x: 1, y: 50)))
        #expect(sim.popup.highlightedRows == [0])
    }

    @Test func freshRowsClearTheHoverAndARestingPointerStaysOut() {
        let sim = simWithRows()
        sim.send(.rowHover(row: 3, pointer: CGPoint(x: 1, y: 1)))
        sim.send(.rowHover(row: 3, pointer: CGPoint(x: 1, y: 2)))
        sim.type("-")
        sim.historyURLs = ["https://a.test/github-", "https://b.test/github-"]
        sim.backspace()
        sim.type("-")
        #expect(sim.popup.highlightedRows == [0])
        sim.send(.rowHover(row: 1, pointer: CGPoint(x: 1, y: 2)))
        #expect(sim.popup.highlightedRows == [0])
    }

    @Test func clickingARowCommitsItWithItsModifiers() {
        let sim = simWithRows()
        sim.send(.rowClick(row: 2, .newBackgroundTab))
        #expect(sim.ended == [.open(URL(string: "https://b.test/github")!, .newBackgroundTab)])
        #expect(sim.popup.rows.isEmpty)
        #expect(!sim.send(.rowClick(row: 0, .currentTab)), "no card, nothing to click")
    }

    @Test func scrollingTheCardChangesNothing() {
        let sim = simWithRows()
        let before = sim.state
        sim.send(.popupScroll)
        #expect(sim.state == before)
    }

    // MARK: Async results

    @Test func staleResultsAreIgnored() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("gi", settle: false)
        let first = sim.queries.first!
        sim.type("th", settle: false)
        sim.send(.suggestions(generation: first.generation, rows: sim.rows(for: first.text)))
        #expect(sim.popup.rows.isEmpty)
        #expect(sim.field.text == "gith")
        sim.answer()
        #expect(sim.field.text == "github.com")
        #expect(sim.field.selection == range(4, 6))
    }

    @Test func resultsAfterFocusLeftAreIgnored() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("gi", settle: false)
        let pending = sim.queries.last!
        sim.key(.escape)
        sim.send(.suggestions(generation: pending.generation, rows: sim.rows(for: pending.text)))
        #expect(sim.popup.rows.isEmpty)
        #expect(sim.field.text == pageText)
    }

    @Test func resultsWhileArrowingKeepTheChosenRow() {
        let sim = OmnibarSim()
        sim.historyURLs = ["https://a.test/docs", "https://b.test/docs"]
        sim.focus()
        sim.type("docs")
        sim.key(.down)
        sim.key(.down)
        #expect(sim.field.text == "https://b.test/docs")
        sim.send(.searchEngineChanged)
        sim.historyURLs = ["https://b.test/docs", "https://a.test/docs"]
        sim.answer()
        #expect(sim.field.text == "https://b.test/docs")
        #expect(sim.state.popup.selected == 1)
    }

    // MARK: IME

    @Test func compositionNeverCompletesOrWritesTheField() {
        let sim = OmnibarSim()
        sim.focus()
        sim.compose("g")
        sim.compose("gi") // marked, e.g. a Japanese IME before conversion
        #expect(sim.state.isComposing)
        #expect(sim.field.text == "gi")
        sim.answer() // github.com would complete "gi"
        #expect(sim.state.edit.inlineCompletion.isEmpty)
        #expect(sim.field.text == "gi")
        #expect(sim.popup.rows.count > 1, "rows still show while composing")
        #expect(!sim.key(.down), "arrows belong to the input method while composing")
        #expect(!sim.key(.enter(.currentTab)))
        #expect(!sim.key(.escape))
        #expect(!sim.send(.rowClick(row: 1, .currentTab)), "the view commits marked text before a row click")
        #expect(!sim.send(.pasteAndGo("example.com")))
        sim.commitComposition("gi")
        #expect(!sim.state.isComposing)
        sim.answer()
        #expect(sim.field.text == "github.com")
        #expect(sim.field.selection == range(2, 8))
        #expect(sim.field.writesWhileMarked == 0)
    }

    @Test func japaneseKanaCompositionShowsRowsWithoutCompletion() {
        let sim = OmnibarSim()
        sim.historyURLs = ["https://example.com/にほん"]
        sim.focus()
        sim.compose("に")
        sim.compose("にほ")
        sim.answer()
        #expect(sim.field.text == "にほ")
        #expect(sim.popup.rows.count == 2)
        #expect(sim.field.writesWhileMarked == 0)
    }

    @Test func convertedKanjiCommitsAsTypedText() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("cmux ")
        sim.compose("にほん")
        sim.commitComposition("日本")
        sim.answer()
        #expect(sim.field.text == "cmux 日本")
        #expect(sim.state.edit.userText == "cmux 日本")
        sim.key(.undo)
        #expect(sim.field.text == "cmux ")
    }

    // MARK: Page and engine

    @Test func navigationWhileEditingNeverOverwritesTypedText() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("foo")
        let next = URL(string: "https://github.com/manaflow-ai/cmux/pulls")!
        sim.send(.pageURLChanged(next))
        #expect(sim.field.text == "foo")
        #expect(sim.field.selection == range(3, 0))
        sim.key(.escape)
        #expect(sim.field.text == "https://github.com/manaflow-ai/cmux/pulls")
    }

    @Test func untouchedTextFollowsThePage() {
        let sim = OmnibarSim()
        sim.focus()
        sim.send(.pageURLChanged(URL(string: "https://example.com/redirected")!))
        #expect(sim.field.text == "https://example.com/redirected")
        #expect(sim.field.selection == range(0, 30))
        sim.moveSelection(to: range(5, 0))
        sim.send(.pageURLChanged(URL(string: "https://e.x/")!))
        #expect(sim.field.selection == range(5, 0))
    }

    @Test func aPageChangeWhileCommittingShowsTheNewPage() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("cmux.dev")
        sim.key(.enter(.currentTab))
        sim.send(.pageURLChanged(URL(string: "https://cmux.dev/home")!))
        #expect(sim.field.text == "cmux.dev/home")
        sim.blur()
        #expect(sim.state.phase == .idle)
        #expect(sim.ended == [.commit(URL(string: "https://cmux.dev")!)], "no blur event after a commit")
    }

    @Test func switchingTheSearchEngineRequeries() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("hello world")
        sim.resolver.searchEngine = .duckDuckGo
        sim.send(.searchEngineChanged)
        #expect(sim.state.popup.stale)
        sim.answer()
        #expect(sim.popup.rows.first?.url.host() == "duckduckgo.com")
        sim.key(.enter(.currentTab))
        guard case .commit(let url) = sim.ended.last else { Issue.record("no commit"); return }
        #expect(url.host() == "duckduckgo.com")
    }
}
