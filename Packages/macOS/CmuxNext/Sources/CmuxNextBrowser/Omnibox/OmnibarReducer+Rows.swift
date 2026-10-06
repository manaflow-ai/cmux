import Foundation

/// Rows that commit differently: Switch to Tab rows, and the typed-URL mark
/// a commit of the default row carries.
nonisolated extension OmnibarStep {
    /// The row Enter takes now: the keyboard selection, unless it is the
    /// default row of rows made for older text.
    var chosenRow: BrowserSuggestion? {
        guard state.phase == .editing, let selected = state.popup.selected,
              state.popup.rows.indices.contains(selected), selected > 0 || !state.popup.stale else { return nil }
        return state.popup.rows[selected]
    }

    /// The URL Enter loads when it is the typed text itself (what-you-typed
    /// or its inline completion, not an arrowed row and not a search), else nil.
    var typedDestination: URL? {
        guard state.phase == .editing else { return nil }
        if let row = chosenRow {
            guard state.popup.selected == 0, [.navigate, .history, .bookmark].contains(row.kind) else { return nil }
            return row.url
        }
        if case .url(let url)? = resolver.destination(for: state.fieldText) { return url }
        return nil
    }

    /// Phase B rows of the current query join the card by the merge rule:
    /// the keyboard selection, the hover and every row at or above them stay.
    mutating func moreSuggestionsArrived(_ rows: [BrowserSuggestion], generation: UInt64, capacity: Int) {
        guard generation == state.generation, state.phase == .editing, state.keyword == nil,
              !state.popup.rows.isEmpty, !state.popup.stale else { return }
        let highlight = max(state.popup.highlighted ?? 0, state.popup.selected ?? 0)
        state.popup.rows = OmniboxMerge.merge(visible: state.popup.rows, highlight: highlight, incoming: rows, capacity: capacity)
    }

    /// Enter or a click on a Switch to Tab row reveals that tab and leaves
    /// this omnibar as it was; Shift (the new-window chord) loads the page
    /// here instead, and the other new-tab chords open it as any row does.
    mutating func switchToTab(_ row: BrowserSuggestion, key: String, _ disposition: OmnibarInput.Disposition) {
        switch disposition {
        case .currentTab:
            leaveKeyword(restoreText: false)
            state.phase = .idle
            state.retainedText = nil
            endSession()
            effects.append(.cancelQuery)
            effects.append(.ended(.switchToTab(key: key)))
        case .newWindow:
            commit(row.url, .currentTab)
        case .newBackgroundTab, .newForegroundTab:
            commit(row.url, disposition)
        }
    }
}
