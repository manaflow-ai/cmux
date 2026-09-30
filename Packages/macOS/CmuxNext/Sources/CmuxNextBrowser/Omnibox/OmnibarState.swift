public import Foundation

/// Everything the omnibar knows, as one value. `OmnibarReducer` is the only
/// writer; the field, the suggestion panel and the chip are drawn from it
/// (`OmnibarPresentation`). See plans/cmux-next/focus.md, section "Omnibar".
public nonisolated struct OmnibarState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// No keyboard focus. The field shows the compact page URL, or the
        /// text the user left there when focus moved away (`retainedText`).
        case idle
        /// Focused, text untouched: the full page URL, all selected on entry.
        /// Page URL changes replace the text.
        case focused
        /// The user changed the text. Page URL changes never touch it.
        case editing
        /// Enter, a row click or Paste and Go loaded `display`; focus is on its
        /// way back to the page. The field shows `display` compactly.
        case committing(display: URL?)
    }

    /// The field while focused or editing. `text` is exactly what the user
    /// typed (marked IME text included); `inlineCompletion` is the selected
    /// suffix shown after it.
    public struct Edit: Equatable, Sendable {
        public var userText = ""
        public var inlineCompletion = ""
        /// UTF-16 range in the field text, as `NSTextView` reports it.
        public var selection = NSRange(location: 0, length: 0)
        /// IME marked (composing) range. While set, nothing completes inline
        /// and the field is never written.
        public var marked: NSRange?
        /// The last edit deleted, cut, or happened before the end of the
        /// text, so no inline completion may follow it (Chrome).
        public var suppressCompletion = false
    }

    /// Who moved the highlight last.
    public enum HighlightSource: Equatable, Sendable { case keyboard, mouse }

    public struct Popup: Equatable, Sendable {
        public var rows: [BrowserSuggestion] = []
        /// The keyboard selection. Drives the field text and Enter. Row 0 is
        /// the default match (what was typed, or the inline completion).
        public var selected: Int?
        /// The row under a pointer that actually moved.
        public var hover: Int?
        public var source: HighlightSource = .keyboard
        /// Last pointer location (screen points) seen over the rows. A hover
        /// at the same location is not movement and is ignored.
        public var pointer: CGPoint?
        /// The rows were produced for older text (the user typed on).
        public var stale = false

        /// The one row drawn highlighted.
        public var highlighted: Int? {
            if source == .mouse, let hover, rows.indices.contains(hover) { return hover }
            if let selected, rows.indices.contains(selected) { return selected }
            return nil
        }
    }

    /// One entry of the omnibar's own undo stack (the field editor's undo is
    /// off, because the state machine rewrites the field).
    public struct UndoEntry: Equatable, Sendable {
        public var text: String
        public var selection: NSRange
        /// The text was the untouched page URL.
        public var untouched: Bool
    }

    public enum EditKind: Equatable, Sendable { case insert, delete, paste }

    /// The mouse press the field is tracking (Chrome `OmniboxViewViews`
    /// `is_mouse_pressed_` and `select_all_on_mouse_release_`).
    public struct Mouse: Equatable, Sendable {
        /// A press is down. False while focus arrived from a click whose
        /// press the field has not reported yet (AppKit makes the field first
        /// responder before it forwards the mouse-down).
        public var pressed: Bool
        public var clickCount: Int
        public var button: OmnibarInput.MouseButton
        /// The press focused the field: select all on release unless it
        /// dragged a selection of its own.
        public var selectAllOnRelease: Bool
        /// The word under a single click on the elided, all-selected URL, in
        /// elided coordinates (Chrome `next_double_click_selection_*`).
        public var wordAtPress: NSRange?
    }

    public var phase: Phase = .idle
    public var pageURL: URL?
    public var retainedText: String?
    public var edit = Edit()
    public var popup = Popup()
    /// Bumped by every suggestion query; results carry it back.
    public var generation: UInt64 = 0
    /// `focused` only: the field shows the steady-state URL
    /// (`BrowserURLDisplay.displayText`, no scheme, no `www.`) instead of the
    /// full URL. A focusing click and Escape keep it elided while all of it
    /// is selected; any other selection, Home, Cmd-L or an edit shows the
    /// full URL (Chrome `OmniboxViewViews::UnapplySteadyStateElisions`).
    public var elided = false
    /// The mouse press in the field, while one is down.
    public var mouse: Mouse?
    /// The word a following double-click selects, in full-URL coordinates,
    /// after a single click unelided the text under the pointer.
    public var doubleClickWord: NSRange?
    public var undo: [UndoEntry] = []
    public var redo: [UndoEntry] = []
    /// Consecutive edits of one kind share one undo entry.
    public var lastEditKind: EditKind?

    public init(pageURL: URL? = nil) { self.pageURL = pageURL }

    // MARK: Derived

    public var hasFocus: Bool {
        switch phase {
        case .focused, .editing: true
        case .idle, .committing: false
        }
    }

    public var isComposing: Bool { edit.marked != nil }

    /// The full page URL (Chrome `url_for_editing_`).
    public var permanentText: String { BrowserURLDisplay.editingText(for: pageURL) }

    /// The steady-state page URL (Chrome `display_text_`).
    public var displayText: String { BrowserURLDisplay.displayText(for: pageURL) }

    /// True when focusing may show the elided URL: it differs from the full one.
    var canElide: Bool { !permanentText.isEmpty && displayText != permanentText }

    /// Exactly what the field must contain.
    public var fieldText: String {
        switch phase {
        case .idle: retainedText ?? BrowserURLDisplay.displayText(for: pageURL)
        case .committing(let display): BrowserURLDisplay.displayText(for: display)
        case .focused: elided ? displayText : permanentText
        case .editing:
            if let selected = popup.selected, selected > 0, popup.rows.indices.contains(selected) {
                OmnibarRules.fillText(for: popup.rows[selected])
            } else {
                edit.userText + edit.inlineCompletion
            }
        }
    }

    /// The selected suffix range while an inline completion shows.
    var completionRange: NSRange {
        NSRange(location: OmnibarRules.length(edit.userText), length: OmnibarRules.length(edit.inlineCompletion))
    }

    /// True when the suggestion panel is on screen.
    public var isPopupOpen: Bool { phase == .editing && !popup.rows.isEmpty }
}
