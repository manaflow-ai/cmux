public import Foundation

/// The result of one reducer step.
public nonisolated struct OmnibarTransition: Equatable, Sendable {
    public var state: OmnibarState
    public var effects: [OmnibarEffect]
    /// The input was consumed. For keys, false means the field editor runs
    /// its default (caret movement, focus traversal, IME handling).
    public var handled: Bool
}

/// The omnibar state machine: `(state, input) -> (state, effects)`, pure.
/// Rules are in plans/cmux-next/focus.md, section "Omnibar"; each input's
/// handling is in this file and its `+Editing` and `+Popup` extensions.
public nonisolated enum OmnibarReducer {
    public static func reduce(_ state: OmnibarState, _ input: OmnibarInput, resolver: OmniboxResolver) -> OmnibarTransition {
        var step = OmnibarStep(state: state, resolver: resolver)
        step.handle(input)
        return OmnibarTransition(state: step.state, effects: step.effects, handled: step.handled)
    }

    /// Undo entries kept per editing session.
    static let undoLimit = 100
}

/// One reducer step: the state being built and the effects it asks for.
nonisolated struct OmnibarStep {
    var state: OmnibarState
    var effects: [OmnibarEffect] = []
    var handled = true
    let resolver: OmniboxResolver

    mutating func handle(_ input: OmnibarInput) {
        switch input {
        case .focusGained(let source): focusGained(source)
        case .focusLost: focusLost()
        case .fieldChanged(let field, let kind): fieldChanged(field, kind)
        case .key(let pressed): key(pressed)
        case .fieldMouseDown(let clicks, let button, let word): fieldMouseDown(clicks, button, word: word)
        case .fieldMouseUp: fieldMouseUp()
        case .rowHover(let row, let pointer): rowHover(row, pointer: pointer)
        case .rowClick(let row, let disposition): rowClick(row, disposition)
        case .popupScroll: break // at most 8 rows: the card never scrolls, the wheel is swallowed
        case .suggestions(let generation, let rows): suggestionsArrived(rows, generation: generation)
        case .moreSuggestions(let generation, let rows, let capacity): moreSuggestionsArrived(rows, generation: generation, capacity: capacity)
        case .pageURLChanged(let url): pageURLChanged(url)
        case .searchEngineChanged: if state.phase == .editing { refreshSuggestions(keepSelection: true) }
        case .pasteAndGo(let text): pasteAndGo(text)
        }
    }

    // MARK: Focus

    mutating func focusGained(_ source: OmnibarInput.FocusSource) {
        switch state.phase {
        case .idle, .committing: beginFocus(source)
        case .focused, .editing: break
        }
    }

    /// Focus arrived: the URL all selected, or the text left behind when
    /// focus last moved away, all selected. Keyboard focus
    /// (Cmd-L) shows the full URL (Chromium `OmniboxViewViews::SetFocus` calls
    /// `OmniboxEditModel::Unelide`); a click or a programmatic focus keeps
    /// the steady-state text until the selection changes.
    mutating func beginFocus(_ source: OmnibarInput.FocusSource) {
        let retained = state.retainedText ?? ""
        state.retainedText = nil
        state.popup = .init()
        state.undo = []
        state.redo = []
        state.lastEditKind = nil
        state.doubleClickWord = nil
        if retained.isEmpty {
            state.editHasPaste = false
            state.phase = .focused
            state.elided = source != .keyboard && state.canElide
            state.edit = .init(selection: Self.all(state.fieldText))
        } else {
            state.phase = .editing
            state.elided = false
            state.edit = .init(userText: retained, selection: Self.all(retained), suppressCompletion: true)
        }
        // AppKit makes the field first responder before it forwards the
        // press: remember that this focus belongs to a click.
        if source == .mouse, state.mouse == nil {
            state.mouse = .init(pressed: false, clickCount: 0, button: .left, selectAllOnRelease: true)
        }
        effects.append(.began)
    }

    mutating func focusLost() {
        let wasFocused = state.hasFocus
        if state.keyword != nil {
            // The session's text means nothing without its keyword.
            leaveKeyword(restoreText: false)
            state.edit = .init()
        }
        if state.phase == .editing {
            // Chromium `OmniboxViewViews::OnBlur`: typed text that equals the
            // permanent display text reverts to it.
            let text = state.visibleUserText
            state.retainedText = text.isEmpty || text == state.displayText ? nil : text
        }
        state.phase = .idle
        endSession()
        if wasFocused { effects.append(.ended(.blur)) }
    }

    /// Clears everything that lives only while the field has focus.
    mutating func endSession() {
        state.edit = .init()
        closePopup()
        state.elided = false
        state.mouse = nil
        state.doubleClickWord = nil
        state.undo = []
        state.redo = []
        state.lastEditKind = nil
    }

    // MARK: Page and commit

    mutating func pageURLChanged(_ url: URL?) {
        guard url != state.pageURL else { return }
        state.pageURL = url
        switch state.phase {
        case .idle:
            // A navigation supersedes text left behind by an earlier blur.
            state.retainedText = nil
        case .focused:
            // Chromium `OmniboxViewViews::Update`: new permanent text while the
            // user has not typed reverts to the display text, all selected.
            state.elided = state.canElide
            state.edit = .init(selection: Self.all(state.fieldText))
            state.doubleClickWord = nil
        case .editing:
            break // never overwrite what the user typed; Escape reverts to the new URL
        case .committing:
            state.phase = .committing(display: url)
        }
    }

    mutating func pasteAndGo(_ text: String) {
        // The view commits marked text first; never commit around the IME.
        guard !state.isComposing else {
            handled = false
            return
        }
        let trimmed = OmnibarRules.singleLine(text).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = resolver.destination(for: trimmed)?.url else {
            effects.append(.beep)
            return
        }
        leaveKeyword(restoreText: false)
        commit(url, .currentTab)
    }

    /// Loads `url` and ends editing; the chrome returns focus to the page
    /// through the focus coordinator.
    mutating func commit(_ url: URL, _ disposition: OmnibarInput.Disposition) {
        let here = disposition == .currentTab
        if here { state.pageURL = url }
        state.phase = .committing(display: state.pageURL)
        state.retainedText = nil
        state.editHasPaste = false
        endSession()
        effects.append(.cancelQuery)
        effects.append(.ended(here ? .commit(url) : .open(url, disposition)))
    }

    /// Where Enter goes now, nil when the text resolves to nothing.
    var commitDestination: URL? {
        switch state.phase {
        case .focused:
            let text = state.permanentText
            return text.isEmpty ? nil : resolver.destination(for: text)?.url
        case .editing:
            let popup = state.popup
            if let selected = popup.selected, popup.rows.indices.contains(selected), selected > 0 || !popup.stale {
                return popup.rows[selected].url
            }
            return resolver.destination(for: state.fieldText)?.url
        case .idle, .committing:
            return nil
        }
    }

    // MARK: Suggestions

    /// Asks for rows for the typed text, or closes the popup when it is blank.
    mutating func query() {
        if let keyword = state.keyword { return keywordQuery(keyword) }
        guard !state.edit.userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            closePopup()
            effects.append(.cancelQuery)
            return
        }
        state.generation &+= 1
        effects.append(.query(generation: state.generation, text: state.edit.userText))
    }

    /// The visible rows no longer match the text: keep them on screen until
    /// fresh ones arrive, but Enter no longer picks them. After an edit the
    /// highlight returns to the default row (the field shows the typed
    /// text); `keepSelection` keeps an arrowed row (engine switch).
    mutating func refreshSuggestions(keepSelection: Bool = false) {
        if !state.popup.rows.isEmpty {
            state.popup.stale = true
            if !keepSelection {
                state.popup.selected = 0
                state.popup.hover = nil
                state.popup.source = .keyboard
            }
        }
        query()
    }

    mutating func closePopup() {
        state.popup = .init()
    }

    static func all(_ text: String) -> NSRange { NSRange(location: 0, length: OmnibarRules.length(text)) }
    static func caretAtEnd(_ text: String) -> NSRange { NSRange(location: OmnibarRules.length(text), length: 0) }
}

nonisolated extension OmnibarState {
    /// What the user sees as their text: the arrowed row's text, else what
    /// they typed without the inline completion.
    var visibleUserText: String {
        if let selected = popup.selected, selected > 0, popup.rows.indices.contains(selected) {
            return OmnibarRules.fillText(for: popup.rows[selected])
        }
        return edit.userText
    }
}
