import Foundation

/// Extension keyword sessions (`chrome.omnibox` keyword mode).
/// The keyword and a typed space, or Tab after the exact keyword, start a
/// session; the field then holds only the text after the keyword and every
/// change goes to the extension (`keywordInput`), whose suggestions come
/// back as `.suggestions`. Enter hands the text to the extension; Backspace
/// at the start, Escape and blur end the session.
nonisolated extension OmnibarStep {
    /// Starts a session when an insert made the text "<keyword> ...".
    /// Returns true when it did (the caller skips its own query).
    mutating func startKeywordIfTyped(_ text: String, kind: OmnibarState.EditKind) -> Bool {
        guard state.keyword == nil, kind == .insert, !state.isComposing,
              state.edit.selection == Self.caretAtEnd(text),
              let match = OmnibarKeyword.match(text, in: resolver.keywords) else { return false }
        startKeyword(match.keyword, text: match.rest, entry: .space)
        return true
    }

    /// Tab after the exact keyword ("Press Tab to search").
    mutating func startKeywordOnTab() -> Bool {
        guard state.keyword == nil, state.phase == .editing, !state.isComposing,
              state.popup.selected ?? 0 == 0,
              // The typed keyword, or a search engine's site its inline completion shows (`youtu` + `be.com`).
              let keyword = OmnibarKeyword.exact(state.edit.userText, in: resolver.keywords)
                ?? OmnibarKeyword.exact(state.fieldText, in: resolver.keywords.filter { $0.searchEngine != nil })
        else { return false }
        startKeyword(keyword, text: "", entry: .tab)
        return true
    }

    mutating func startKeyword(_ keyword: OmnibarKeyword, text: String, entry: OmnibarState.KeywordEntry) {
        state.keyword = keyword
        state.keywordEntry = entry
        state.phase = .editing
        state.elided = false
        state.edit = .init(userText: text, selection: Self.caretAtEnd(text), suppressCompletion: true)
        state.undo = []
        state.redo = []
        state.lastEditKind = nil
        closePopup()
        if keyword.searchEngine == nil { effects.append(.keywordStarted(extensionID: keyword.extensionID)) }
        query()
    }

    /// Ends the session without Enter. `restoreText` puts back what
    /// Chromium's `OmniboxEditModel::ClearKeyword` does (Backspace at the
    /// start, Cmd-L): the keyword alone, caret after it, right after a Tab
    /// entry with nothing typed; nothing after a shortcut entry; else the
    /// keyword and a space, so typing on does not start the session again.
    mutating func leaveKeyword(restoreText: Bool) {
        guard let keyword = state.keyword else { return }
        state.keyword = nil
        if keyword.searchEngine == nil { effects.append(.keywordEnded(extensionID: keyword.extensionID)) }
        closePopup()
        state.generation &+= 1
        effects.append(.cancelQuery)
        guard restoreText else { return }
        let prefix = switch state.keywordEntry {
        case .tab where state.edit.userText.isEmpty: keyword.keyword
        case .shortcut: ""
        case .tab, .space: keyword.keyword + " "
        }
        let text = prefix + state.edit.userText
        state.edit = .init(userText: text, selection: NSRange(location: OmnibarRules.length(prefix), length: 0),
                           suppressCompletion: true)
        query()
    }

    /// Opt-Cmd-F: an empty session of the default search engine (Chrome
    /// `EnterKeywordModeForDefaultSearchProvider`); typing then searches there.
    mutating func searchWithDefaultEngine() {
        guard state.hasFocus, !state.isComposing else {
            handled = false
            return
        }
        let engine = resolver.searchEngine
        let keyword = resolver.keywords.first { $0.searchEngine?.id == engine.id } ?? OmnibarKeyword(searchEngine: engine)
        if state.keyword == keyword, state.edit.userText.isEmpty { return }
        leaveKeyword(restoreText: false)
        startKeyword(keyword, text: "", entry: .shortcut)
    }

    /// Backspace at the start of a session's text leaves the session.
    mutating func backspaceAtStart() {
        guard state.keyword != nil, state.hasFocus, !state.isComposing,
              state.edit.selection == NSRange(location: 0, length: 0) else {
            handled = false
            return
        }
        leaveKeyword(restoreText: true)
    }

    /// The session's text changed: the extension gets it (also when empty).
    mutating func keywordQuery(_ keyword: OmnibarKeyword) {
        state.generation &+= 1
        // A search engine session has no rows: Enter searches with the engine.
        guard keyword.searchEngine == nil else {
            closePopup()
            effects.append(.cancelQuery)
            return
        }
        effects.append(.keywordInput(extensionID: keyword.extensionID, text: state.edit.userText, generation: state.generation))
    }

    /// Enter or a row click in a session: the extension gets `text`.
    mutating func commitKeyword(_ text: String, _ disposition: OmnibarInput.Disposition) {
        guard let keyword = state.keyword else { return }
        if let engine = keyword.searchEngine {
            // Chrome: Enter in a search engine session searches there; with no
            // text it opens the engine's site.
            state.keyword = nil
            let query = text.trimmingCharacters(in: .whitespaces)
            guard let url = engine.searchURL(for: query) ?? (query.isEmpty ? engine.siteURL : nil) else {
                state.keyword = keyword
                effects.append(.beep)
                return
            }
            return commit(url, disposition)
        }
        state.keyword = nil
        state.phase = .committing(display: state.pageURL)
        state.retainedText = nil
        endSession()
        effects.append(.cancelQuery)
        effects.append(.ended(.keyword(extensionID: keyword.extensionID, text: text, disposition: disposition)))
    }

    /// What Enter sends: the arrowed row's content, else the typed text.
    var keywordCommitText: String {
        let popup = state.popup
        if let selected = popup.selected, selected > 0, popup.rows.indices.contains(selected) {
            return OmnibarRules.fillText(for: popup.rows[selected])
        }
        return state.edit.userText
    }
}
