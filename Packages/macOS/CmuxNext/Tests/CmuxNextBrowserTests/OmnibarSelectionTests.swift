import Foundation
import Testing
@testable import CmuxNextBrowser

/// Selection and focus rules. Each test names the
/// Chromium function it follows (chrome/browser/ui/views/omnibox/
/// omnibox_view_views.cc, chrome/browser/ui/omnibox/omnibox_edit_model.cc,
/// ui/views/selection_controller.cc, components/omnibox/browser/
/// omnibox_text_util.cc). The page is `https://github.com/manaflow-ai/cmux`:
/// 35 UTF-16 units in full, 27 elided (`github.com/manaflow-ai/cmux`), and
/// the elided text starts at offset 8 of the full text.
@MainActor
@Suite struct OmnibarSelectionTests {
    private func range(_ location: Int, _ length: Int) -> NSRange { NSRange(location: location, length: length) }
    let full = "https://github.com/manaflow-ai/cmux"
    let elided = "github.com/manaflow-ai/cmux"

    // MARK: Focusing click (OnMousePressed / OnMouseReleased)

    @Test(arguments: [true, false])
    func aFocusingClickSelectsAllOfTheElidedURLOnRelease(focusFirst: Bool) {
        let sim = OmnibarSim()
        sim.click(selecting: range(7, 0), focusFirst: focusFirst)
        #expect(sim.state.phase == .focused)
        #expect(sim.field.text == elided, "select-all keeps the steady-state text")
        #expect(sim.field.selection == range(0, 27))
        #expect(sim.state.elided)
        #expect(sim.state.mouse == nil)
    }

    @Test func aFocusingDragSelectsTheDraggedRangeInTheFullURL() {
        let sim = OmnibarSim()
        sim.click(selecting: range(11, 8))
        #expect(sim.field.text == full, "a partial selection unelides on release")
        #expect(sim.field.selection == range(19, 8), "\"manaflow\" in the full URL")
        #expect(!sim.state.elided)
    }

    @Test func aDragFromTheStartOfAURLKeepsTheSchemeInTheSelection() {
        // UnapplySteadyStateElisions(kMouseRelease): a URL-like selection that
        // starts at the elided text's start also starts at the full text's.
        let sim = OmnibarSim()
        sim.click(selecting: range(0, 10))
        #expect(sim.field.text == full)
        #expect(sim.field.selection == range(0, 18), "\"https://github.com\"")
    }

    @Test func aDragFromTheStartThatReadsAsASearchOnlyShifts() {
        let sim = OmnibarSim()
        sim.click(selecting: range(0, 6))
        #expect(sim.field.selection == range(8, 6), "\"github\" classifies as a search")
    }

    @Test func aClickInTheFocusedFieldPlacesTheCaretInTheFullURL() {
        let sim = OmnibarSim()
        sim.click(selecting: range(3, 0))
        sim.click(selecting: range(5, 0))
        #expect(sim.field.text == full)
        #expect(sim.field.selection == range(13, 0))
        sim.click(selecting: range(20, 0))
        #expect(sim.field.selection == range(20, 0), "later clicks are plain carets")
    }

    @Test func aDoubleClickOnAnUnfocusedFieldSelectsTheWordInTheFullURL() {
        let sim = OmnibarSim()
        sim.click(selecting: range(2, 0))
        #expect(sim.field.selection == range(0, 27))
        // The second press selects "github" in the elided text.
        sim.click(count: 2, selecting: range(0, 6))
        #expect(sim.field.text == full)
        #expect(sim.field.selection == range(8, 6))
        sim.click(count: 3, selecting: range(0, 35))
        #expect(sim.field.selection == range(0, 35), "triple-click selects all")
    }

    @Test func aDoubleClickAfterAnUnelidingClickKeepsTheWordUnderThePointer() {
        // crbug.com/40693090: the first click of a double-click on the
        // all-selected elided URL unelides; the second press lands on another
        // character of the shifted text. The first word is remembered.
        let sim = OmnibarSim()
        sim.click(selecting: range(2, 0))
        sim.click(word: range(0, 6), selecting: range(2, 0))
        #expect(sim.field.text == full)
        #expect(sim.field.selection == range(10, 0))
        // The field editor picks the word at the same point in the new text.
        sim.click(count: 2, selecting: range(0, 5))
        #expect(sim.field.selection == range(8, 6), "\"github\", not \"https\"")
    }

    // MARK: Right-click (SelectionController::OnMousePressed, PlatformStyle Mac)

    @Test func aRightClickOnAnUnfocusedFieldSelectsAllBeforeTheMenu() {
        let sim = OmnibarSim()
        let atMenu = sim.rightClick()
        #expect(atMenu == range(0, 27))
        #expect(sim.field.selection == range(0, 27))
        #expect(sim.field.text == elided)
    }

    @Test func aRightClickOnAFocusedFieldKeepsTheFieldEditorsWordSelection() {
        let sim = OmnibarSim()
        sim.click(selecting: range(3, 0))
        sim.click(selecting: range(4, 0))
        let atMenu = sim.rightClick(selecting: range(19, 8))
        #expect(atMenu == range(19, 8))
        #expect(sim.field.selection == range(19, 8))
    }

    // MARK: Keyboard focus (SetFocus, OmniboxEditModel::Unelide)

    @Test func keyboardFocusShowsTheFullURLAllSelected() {
        let sim = OmnibarSim()
        sim.focus(.keyboard)
        #expect(sim.field.text == full)
        #expect(sim.field.selection == range(0, 35))
        #expect(!sim.state.elided)
    }

    @Test func cmdLOnTheElidedURLShowsTheFullURLAllSelected() {
        let sim = OmnibarSim()
        sim.click(selecting: range(3, 0))
        #expect(sim.key(.focusLocation))
        #expect(sim.field.text == full)
        #expect(sim.field.selection == range(0, 35))
    }

    @Test func cmdLWhileTypingSelectsTheTypedText() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("hello")
        #expect(sim.key(.focusLocation))
        #expect(sim.field.text == "hello")
        #expect(sim.field.selection == range(0, 5))
    }

    @Test func cmdAKeepsTheElidedURL() {
        let sim = OmnibarSim()
        sim.click(selecting: range(3, 0))
        sim.key(.selectAll)
        #expect(sim.field.text == elided)
        #expect(sim.field.selection == range(0, 27))
    }

    // MARK: Caret keys (OnAfterPossibleChange, HandleKeyEvent VKEY_HOME)

    @Test func rightArrowOnTheElidedURLPutsTheCaretAtTheEndOfTheFullURL() {
        let sim = OmnibarSim()
        sim.click(selecting: range(3, 0))
        sim.moveSelection(to: range(27, 0))
        #expect(sim.field.text == full)
        #expect(sim.field.selection == range(35, 0))
    }

    @Test func leftArrowOnTheElidedURLPutsTheCaretBeforeTheHost() {
        let sim = OmnibarSim()
        sim.click(selecting: range(3, 0))
        sim.moveSelection(to: range(0, 0))
        #expect(sim.field.selection == range(8, 0))
    }

    @Test func homeOnTheElidedURLGoesToTheStartOfTheFullURL() {
        let sim = OmnibarSim()
        sim.click(selecting: range(3, 0))
        #expect(sim.key(.home(extend: false)))
        #expect(sim.field.text == full)
        #expect(sim.field.selection == range(0, 0))
        #expect(!sim.key(.home(extend: false)), "nothing to unelide: the field editor's own Home")
    }

    @Test func typingReplacesTheElidedSelection() {
        let sim = OmnibarSim()
        sim.click(selecting: range(3, 0))
        sim.type("x", settle: false)
        #expect(sim.state.phase == .editing)
        #expect(sim.field.text == "x")
    }

    // MARK: Escape (OmniboxEditModel::OnEscapeKeyPressed)

    @Test func escapeClosesTheCardThenRevertsThenBlurs() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("hello")
        #expect(!sim.popup.rows.isEmpty)
        #expect(sim.key(.escape))
        #expect(sim.popup.rows.isEmpty, "first Escape closes the card")
        #expect(sim.field.text == "hello")
        #expect(sim.state.phase == .editing)
        #expect(sim.key(.escape))
        #expect(sim.state.phase == .focused, "second Escape reverts")
        #expect(sim.field.text == elided, "Revert shows the permanent display text")
        #expect(sim.field.selection == range(0, 27))
        #expect(sim.ended.isEmpty)
        #expect(sim.key(.escape))
        #expect(sim.ended == [.cancel], "third Escape returns focus to the page")
        #expect(sim.state.phase == .idle)
    }

    @Test func escapeFirstRevertsAnArrowedRowToTheTypedText() {
        let sim = OmnibarSim()
        sim.historyURLs = ["https://a.test/github", "https://b.test/github"]
        sim.focus()
        sim.type("github")
        sim.key(.down)
        #expect(sim.field.text == "https://a.test/github")
        #expect(sim.key(.escape))
        #expect(sim.field.text == "github", "temporary text reverts")
        #expect(!sim.popup.rows.isEmpty, "the card stays")
        #expect(sim.popup.highlightedRows == [0])
        #expect(sim.key(.escape))
        #expect(sim.popup.rows.isEmpty)
        #expect(sim.field.text == "github")
    }

    @Test func escapeOnTheUntouchedURLBlursAtOnce() {
        let sim = OmnibarSim()
        sim.click(selecting: range(3, 0))
        #expect(sim.key(.escape))
        #expect(sim.ended == [.cancel])
    }

    // MARK: Blur (OnBlur)

    @Test func blurShowsTheElidedURLAndClearsTheSelection() {
        let sim = OmnibarSim()
        sim.focus(.keyboard)
        sim.moveSelection(to: range(10, 4))
        sim.blur()
        #expect(sim.field.text == elided)
        #expect(sim.field.style == .compactURL(OmnibarSim.page))
        #expect(OmnibarPresentation(sim.state).selection == nil)
    }

    @Test func blurWithTypedTextEqualToTheDisplayTextReverts() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type(elided, settle: false)
        sim.blur()
        #expect(sim.state.retainedText == nil)
        #expect(sim.field.style == .compactURL(OmnibarSim.page))
    }

    // MARK: Navigation while focused (OmniboxViewViews::Update, ResetDisplayTexts)

    @Test func aNavigationWhileFocusedAndUntouchedShowsTheNewURLAllSelected() {
        let sim = OmnibarSim()
        sim.click(selecting: range(3, 0))
        sim.click(selecting: range(5, 0))
        #expect(sim.field.text == full)
        sim.send(.pageURLChanged(URL(string: "https://www.example.com/next")!))
        #expect(sim.field.text == "example.com/next")
        #expect(sim.field.selection == range(0, 16))
    }

    // MARK: Copy (OmniboxEditModel::AdjustTextForCopy)

    @Test func copyingTheWholeElidedURLCopiesTheFullURL() {
        let sim = OmnibarSim()
        sim.click(selecting: range(3, 0))
        #expect(sim.copied == OmnibarCopy(text: full, url: OmnibarSim.page))
    }

    @Test func copyingAPartOfTheURLFromItsStartCopiesAURLWithTheSchemeOfThePage() {
        let sim = OmnibarSim(page: URL(string: "https://github.com/manaflow-ai/cmux")!)
        sim.focus(.keyboard)
        sim.moveSelection(to: range(8, 10)) // "github.com"
        #expect(sim.copied == OmnibarCopy(text: "github.com", url: nil), "not from the start: plain text")
        sim.key(.selectAll)
        sim.type("github.com/foo", settle: false)
        sim.key(.selectAll)
        #expect(sim.copied == OmnibarCopy(text: "https://github.com/foo", url: URL(string: "https://github.com/foo")))
    }

    @Test func copyingASearchCopiesItAsTyped() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("hello world", settle: false)
        sim.key(.selectAll)
        #expect(sim.copied == OmnibarCopy(text: "hello world", url: nil))
    }

    // MARK: Shift-Delete (HandleKeyEvent VKEY_DELETE, TryDeletingPopupLine)

    @Test func shiftDeleteRemovesTheHighlightedHistoryRow() {
        let sim = OmnibarSim()
        sim.historyURLs = ["https://a.test/github", "https://b.test/github"]
        sim.focus()
        sim.type("github")
        sim.key(.down)
        let removed = sim.popup.rows[1].url
        #expect(sim.key(.deleteSuggestion))
        #expect(sim.effects.contains(.deleteSuggestion(removed)))
        #expect(!sim.popup.rows.contains { $0.url == removed })
        #expect(sim.popup.highlightedRows == [1], "the next row takes the highlight")
        #expect(sim.field.text == "https://b.test/github")
        sim.key(.up)
        #expect(!sim.key(.deleteSuggestion), "the typed-text row is not history: the field deletes forward")
    }
}
