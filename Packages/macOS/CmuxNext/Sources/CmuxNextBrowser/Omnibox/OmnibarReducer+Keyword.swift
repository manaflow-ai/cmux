import Foundation

/// Extension keyword sessions (`chrome.omnibox`, Chrome's keyword mode).
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
        startKeyword(match.keyword, text: match.rest)
        return true
    }

    /// Tab after the exact keyword (Chrome "Press Tab to search").
    mutating func startKeywordOnTab() -> Bool {
        guard state.keyword == nil, state.phase == .editing, !state.isComposing,
              state.popup.selected ?? 0 == 0,
              let keyword = OmnibarKeyword.exact(state.edit.userText, in: resolver.keywords) else { return false }
        startKeyword(keyword, text: "")
        return true
    }

    mutating func startKeyword(_ keyword: OmnibarKeyword, text: String) {
        state.keyword = keyword
        state.phase = .editing
        state.elided = false
        state.edit = .init(userText: text, selection: Self.caretAtEnd(text), suppressCompletion: true)
        state.undo = []
        state.redo = []
        state.lastEditKind = nil
        closePopup()
        effects.append(.keywordStarted(extensionID: keyword.extensionID))
        query()
    }

    /// Ends the session without Enter. `restoreText` puts the keyword back
    /// in front of the typed text (Backspace at the start, Chrome).
    mutating func leaveKeyword(restoreText: Bool) {
        guard let keyword = state.keyword else { return }
        state.keyword = nil
        effects.append(.keywordEnded(extensionID: keyword.extensionID))
        closePopup()
        state.generation &+= 1
        effects.append(.cancelQuery)
        guard restoreText else { return }
        let text = keyword.keyword + state.edit.userText
        state.edit = .init(userText: text, selection: NSRange(location: OmnibarRules.length(keyword.keyword), length: 0),
                           suppressCompletion: true)
        query()
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
        effects.append(.keywordInput(extensionID: keyword.extensionID, text: state.edit.userText, generation: state.generation))
    }

    /// Enter or a row click in a session: the extension gets `text`.
    mutating func commitKeyword(_ text: String, _ disposition: OmnibarInput.Disposition) {
        guard let keyword = state.keyword else { return }
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
