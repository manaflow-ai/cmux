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

    public var phase: Phase = .idle
    public var pageURL: URL?
    public var retainedText: String?
    public var edit = Edit()
    public var popup = Popup()
    /// Bumped by every suggestion query; results carry it back.
    public var generation: UInt64 = 0
    /// Click count of the mouse-down that is focusing the field (Chrome: a
    /// single click that focuses selects everything on mouse-up).
    public var focusingClick: Int?
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

    /// The page URL as the field shows it while focused.
    public var permanentText: String { BrowserURLDisplay.editingText(for: pageURL) }

    /// Exactly what the field must contain.
    public var fieldText: String {
        switch phase {
        case .idle: retainedText ?? BrowserURLDisplay.displayText(for: pageURL)
        case .committing(let display): BrowserURLDisplay.displayText(for: display)
        case .focused: permanentText
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
