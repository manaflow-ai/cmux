public import Foundation

/// Every event the omnibar reacts to, from the keyboard, the mouse, the
/// focus coordinator, the suggestion engine and the page.
public nonisolated enum OmnibarInput: Equatable, Sendable {
    /// What the field editor holds right now.
    public struct Field: Equatable, Sendable {
        public var text: String
        public var selection: NSRange
        public var marked: NSRange?

        public init(text: String, selection: NSRange, marked: NSRange? = nil) {
            self.text = text
            self.selection = selection
            self.marked = marked
        }
    }

    /// Where a commit opens.
    public enum Disposition: Equatable, Sendable {
        case currentTab
        /// Cmd-Enter or Cmd-click: a background tab.
        case newBackgroundTab
        /// Option-Enter, Shift-Cmd-Enter.
        case newForegroundTab
        /// Shift-Enter.
        case newWindow
    }

    public enum Key: Equatable, Sendable {
        case up, down, tab, backTab
        case enter(Disposition)
        case escape
        /// Cmd-A (the field editor's `selectAll:`). Never unelides.
        case selectAll
        /// Cmd-L while the field already has focus (Chromium
        /// `OmniboxViewViews::SetFocus(is_user_initiated=true)`): the full
        /// URL, all selected.
        case focusLocation
        /// The Home key (`scrollToBeginningOfDocument:`; Shift-Home extends).
        /// Unelides even from select-all (Chromium `UnelisionGesture::kHomeKeyPressed`).
        case home(extend: Bool)
        /// Shift-Delete (forward delete): removes the highlighted history row
        /// (Chromium `OmniboxEditModel::TryDeletingPopupLine`).
        case deleteSuggestion
        case undo, redo
        /// Backspace with the caret at the start of the text: leaves an
        /// extension keyword session (not handled outside one).
        case backspaceAtStart
    }

    public enum FocusSource: Equatable, Sendable { case mouse, keyboard, programmatic }

    public enum MouseButton: Equatable, Sendable { case left, right }

    // Focus (AppKit responder changes the FocusCoordinator caused or saw).
    case focusGained(FocusSource)
    case focusLost

    /// The field editor changed. `kind` is set for a text edit (typing,
    /// deletion, paste, cut, IME composition) and nil for a selection-only
    /// change (caret move, click or drag selection, Cmd-A). Typing the next
    /// character of a selected inline completion is an edit with unchanged text.
    case fieldChanged(Field, OmnibarState.EditKind?)

    /// A key the field editor forwards before its own handling.
    case key(Key)

    // Mouse in the field. `word` is the word range under the pointer in the
    // text the field shows at the press (the field editor's word granularity);
    // the machine uses it to fix the second click of a double-click that
    // follows an unelision (Chromium crbug.com/40693090).
    case fieldMouseDown(clickCount: Int, button: MouseButton = .left, word: NSRange? = nil)
    case fieldMouseUp

    // Mouse over suggestion rows. `row` nil: the pointer left the rows.
    case rowHover(row: Int?, pointer: CGPoint)
    case rowClick(row: Int, Disposition)
    case popupScroll

    /// Results of the query with `generation`.
    case suggestions(generation: UInt64, rows: [BrowserSuggestion])
    /// Late (phase B) rows of the query with `generation`, merged into the
    /// card without moving what is on screen (`OmniboxMerge`).
    case moreSuggestions(generation: UInt64, rows: [BrowserSuggestion], capacity: Int)

    case pageURLChanged(URL?)
    case searchEngineChanged
    case pasteAndGo(String)
}

/// Side effects the reducer asks for. `OmnibarController` runs them after
/// the reducer returns, never inside it.
public nonisolated enum OmnibarEffect: Equatable, Sendable {
    /// Ask the suggestion engine for `text`; answer with `.suggestions`.
    case query(generation: UInt64, text: String)
    case cancelQuery
    case beep
    /// Public editing boundaries (`OmnibarEvent`). The chrome loads a commit
    /// and hands focus back to the page through the focus coordinator.
    case began
    case ended(OmnibarEndReason)
    /// Shift-Delete removed this history row: forget the page.
    case deleteSuggestion(URL)
    /// Enter loaded the typed text as a URL (what-you-typed or its inline
    /// completion): the visit counts as typed (Chromium `PAGE_TRANSITION_TYPED`).
    case typedNavigation(URL)
    /// Enter fixed a top-level-domain typo in this typed host
    /// (`HostTypoFixup`): remember it, so typing it again loads it as typed.
    case hostTypoFixed(typedHost: String)
    /// Enter or a click on a calculator row: copy this answer.
    case copyAnswer(String)
    /// An extension keyword session started (`chrome.omnibox.onInputStarted`).
    case keywordStarted(extensionID: String)
    /// The session's text changed; answer with `.suggestions(generation:)`.
    case keywordInput(extensionID: String, text: String, generation: UInt64)
    /// The session ended without Enter (`onInputCancelled`).
    case keywordEnded(extensionID: String)
}
