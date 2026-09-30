import Foundation

/// Keys, the suggestion rows (keyboard and mouse), and async results.
nonisolated extension OmnibarStep {
    mutating func key(_ key: OmnibarInput.Key) {
        switch key {
        case .up: move(-1, clamp: true)
        case .down: move(1, clamp: true)
        case .tab: move(1, clamp: false)
        case .backTab: move(-1, clamp: false)
        case .enter(let disposition): enter(disposition)
        case .escape: escape()
        case .selectAll: selectAll()
        case .undo: undo(redo: false)
        case .redo: undo(redo: true)
        }
    }

    /// Up/Down clamp at both ends. Tab/Shift-Tab past either end are not
    /// handled, so focus leaves the field (Chrome).
    private mutating func move(_ delta: Int, clamp: Bool) {
        guard state.isPopupOpen, !state.isComposing else {
            handled = false
            return
        }
        let current = state.popup.selected ?? 0
        let next = current + delta
        guard state.popup.rows.indices.contains(next) || clamp else {
            handled = false
            return
        }
        select(min(max(next, 0), state.popup.rows.count - 1))
    }

    /// The keyboard highlight moves to `row`; the field shows its text.
    private mutating func select(_ row: Int) {
        state.popup.selected = row
        state.popup.hover = nil
        state.popup.source = .keyboard
        state.lastEditKind = nil
        if row > 0 {
            state.edit.selection = Self.caretAtEnd(state.fieldText)
        } else if state.edit.inlineCompletion.isEmpty {
            state.edit.selection = Self.caretAtEnd(state.edit.userText)
        } else {
            state.edit.selection = state.completionRange
        }
    }

    private mutating func enter(_ disposition: OmnibarInput.Disposition) {
        guard state.hasFocus, !state.isComposing else {
            // No focus: the field editor outlived editing; IME: the input
            // method commits the composition.
            handled = false
            return
        }
        guard let destination = commitDestination else {
            effects.append(.beep)
            return
        }
        commit(destination, disposition)
    }

    /// First Escape reverts to the page URL (all selected, Cmd-Z brings the
    /// text back); with nothing to revert it cancels editing.
    private mutating func escape() {
        guard state.hasFocus, !state.isComposing else {
            handled = false
            return
        }
        if state.phase == .editing {
            pushUndo()
            state.phase = .focused
            state.edit = .init(selection: Self.all(state.permanentText))
            state.lastEditKind = nil
            closePopup()
            effects.append(.cancelQuery)
        } else {
            state.phase = .idle
            endSession()
            effects.append(.ended(.cancel))
        }
    }

    // MARK: Results

    mutating func suggestionsArrived(_ rows: [BrowserSuggestion], generation: UInt64) {
        // Only the latest query counts; anything else is stale.
        guard generation == state.generation, state.phase == .editing else { return }
        if let selected = state.popup.selected, selected > 0, state.popup.rows.indices.contains(selected) {
            // The user is arrowing through rows: keep their row, or keep the
            // rows they are looking at when it is gone.
            let chosen = state.popup.rows[selected]
            guard let index = rows.firstIndex(where: { $0.url == chosen.url }), index > 0 else { return }
            state.popup.rows = rows
            state.popup.selected = index
            state.popup.stale = false
            return
        }
        var rows = rows
        let text = state.edit.userText
        let atEnd = state.edit.selection == Self.caretAtEnd(text)
            || (!state.edit.inlineCompletion.isEmpty && state.edit.selection == state.completionRange)
        let mayComplete = !state.isComposing && !state.edit.suppressCompletion && atEnd
        state.edit.inlineCompletion = ""
        if mayComplete,
           let index = rows.firstIndex(where: { OmnibarRules.inlineCompletion(for: $0, typed: text) != nil }),
           let completion = OmnibarRules.inlineCompletion(for: rows[index], typed: text) {
            // The completed row becomes the default match.
            rows.insert(rows.remove(at: index), at: 0)
            state.edit.inlineCompletion = completion
            state.edit.selection = state.completionRange
        } else if mayComplete {
            state.edit.selection = Self.caretAtEnd(text)
        }
        guard !rows.isEmpty else {
            closePopup()
            return
        }
        let wasOpen = !state.popup.rows.isEmpty
        state.popup.rows = rows
        state.popup.selected = 0
        state.popup.hover = nil
        state.popup.source = .keyboard
        state.popup.stale = false
        if !wasOpen { state.popup.pointer = nil }
    }

    // MARK: Mouse over rows

    /// Hover highlights a row only after the pointer actually moved, so a
    /// card opening under a resting pointer never steals the keyboard
    /// highlight (Chrome).
    mutating func rowHover(_ row: Int?, pointer: CGPoint) {
        guard state.isPopupOpen, state.popup.pointer != pointer else { return }
        let first = state.popup.pointer == nil
        state.popup.pointer = pointer
        guard !first else { return }
        if let row, state.popup.rows.indices.contains(row) {
            state.popup.hover = row
            state.popup.source = .mouse
        } else {
            state.popup.hover = nil
        }
    }

    mutating func rowClick(_ row: Int, _ disposition: OmnibarInput.Disposition) {
        // The view commits marked text first; never commit around the IME.
        guard state.isPopupOpen, state.popup.rows.indices.contains(row), !state.isComposing else {
            handled = false
            return
        }
        commit(state.popup.rows[row].url, disposition)
    }
}
