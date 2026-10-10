import Foundation

/// Field editor changes: typing, deletion, paste, IME composition, caret
/// and selection moves, the focusing click, and undo.
nonisolated extension OmnibarStep {
    mutating func fieldChanged(_ field: OmnibarInput.Field, _ kind: OmnibarState.EditKind?) {
        let textChanged = field.text != state.fieldText
        let unchanged = !textChanged && field.selection == state.edit.selection && field.marked == state.edit.marked
        if unchanged, state.hasFocus { return }
        if !state.hasFocus {
            // The field editor outlived editing (commit or cancel, focus on
            // its way to the page): only a real edit starts editing again.
            // A selection report is not one: AppKit reloads the field's old
            // text when the field becomes first responder again.
            guard textChanged, kind != nil else { return }
            beginFocus(.programmatic)
        }
        if field.text != state.fieldText || kind != nil || field.marked != state.edit.marked && field.marked != nil {
            edit(field, kind ?? .insert)
        } else {
            selectionChanged(field)
        }
    }

    // MARK: Text

    private mutating func edit(_ field: OmnibarInput.Field, _ kind: OmnibarState.EditKind) {
        let wasComposing = state.isComposing
        // An edit is user input: nothing left to unelide or remember.
        if state.mouse?.pressed == false { state.mouse = nil }
        state.doubleClickWord = nil
        defer { state.elided = false }
        if let marked = field.marked {
            // IME composition: record it, never complete, never write.
            if !wasComposing { pushUndo() }
            state.lastEditKind = nil
            state.phase = .editing
            let length = OmnibarRules.length(field.text)
            state.edit = .init(
                userText: field.text,
                selection: OmnibarRules.clamped(field.selection, length: length),
                marked: OmnibarRules.clamped(marked, length: length),
                suppressCompletion: true
            )
            refreshSuggestions()
            return
        }

        let text = kind == .paste ? OmnibarRules.singleLine(field.text) : field.text
        if !wasComposing, kind != state.lastEditKind || kind == .paste { pushUndo() }
        state.lastEditKind = kind == .paste ? nil : kind
        let previous = state.edit.userText + state.edit.inlineCompletion
        let hadCompletion = !state.edit.inlineCompletion.isEmpty && state.phase == .editing
        let length = OmnibarRules.length(text)
        let selection = OmnibarRules.clamped(field.selection, length: length)
        let atEnd = selection == Self.caretAtEnd(text)
        state.phase = .editing
        state.edit = .init(userText: text, selection: selection, suppressCompletion: kind != .insert || !atEnd)

        // Typing the next characters of a shown completion keeps the rest
        // of it on screen until fresh rows arrive (no flicker).
        if hadCompletion, kind == .insert, atEnd, !wasComposing,
           previous.count > text.count, previous.lowercased().hasPrefix(text.lowercased()) {
            state.edit.inlineCompletion = String(previous.dropFirst(text.count))
            state.edit.selection = state.completionRange
        }
        if startKeywordIfTyped(text, kind: kind) { return }
        refreshSuggestions()
    }

    /// Pushes the text as it is now onto the undo stack.
    mutating func pushUndo() {
        guard state.hasFocus else { return }
        let entry = currentUndoEntry
        if state.undo.last != entry { state.undo.append(entry) }
        if state.undo.count > OmnibarReducer.undoLimit { state.undo.removeFirst() }
        state.redo = []
    }

    private var currentUndoEntry: OmnibarState.UndoEntry {
        let text = state.phase == .focused ? state.fieldText : state.visibleUserText
        return .init(
            text: text,
            selection: OmnibarRules.clamped(state.edit.selection, length: OmnibarRules.length(text)),
            untouched: state.phase == .focused
        )
    }

    // MARK: Selection

    private mutating func selectionChanged(_ field: OmnibarInput.Field) {
        guard field.selection != state.edit.selection || field.marked != state.edit.marked else { return }
        state.lastEditKind = nil
        if state.phase == .focused {
            state.edit.selection = OmnibarRules.clamped(field.selection, length: OmnibarRules.length(state.fieldText))
            state.edit.marked = nil
            // Chromium `OnAfterPossibleChange`: a keystroke or caret move
            // unelides; a press defers it to the release.
            if state.mouse == nil { unelide(.other) }
            return
        }
        let compositionEnded = state.isComposing && field.marked == nil
        state.edit.marked = field.marked
        var requery = compositionEnded
        if let selected = state.popup.selected, selected > 0, state.popup.rows.indices.contains(selected) {
            // Moving the caret in an arrowed row's text makes it the typed text.
            state.edit.userText = state.fieldText
            state.edit.inlineCompletion = ""
            state.edit.suppressCompletion = true
            requery = true
        } else if !state.edit.inlineCompletion.isEmpty, field.selection != state.completionRange {
            // Any caret move accepts the inline completion as typed text.
            state.edit.userText += state.edit.inlineCompletion
            state.edit.inlineCompletion = ""
            state.edit.suppressCompletion = true
        }
        let text = state.fieldText
        state.edit.selection = OmnibarRules.clamped(field.selection, length: OmnibarRules.length(text))
        if compositionEnded { state.edit.suppressCompletion = state.edit.selection != Self.caretAtEnd(text) }
        if requery { refreshSuggestions() }
    }

    // MARK: Undo

    mutating func undo(redo isRedo: Bool) {
        guard state.hasFocus, !state.isComposing else {
            handled = false
            return
        }
        guard let entry = isRedo ? state.redo.popLast() : state.undo.popLast() else { return }
        let current = currentUndoEntry
        if isRedo { state.undo.append(current) } else { state.redo.append(current) }
        state.lastEditKind = nil
        if entry.untouched {
            state.phase = .focused
            state.elided = state.canElide && entry.text == state.displayText
            state.edit = .init(selection: OmnibarRules.clamped(entry.selection, length: OmnibarRules.length(state.fieldText)))
            closePopup()
            effects.append(.cancelQuery)
        } else {
            state.phase = .editing
            state.edit = .init(
                userText: entry.text,
                selection: OmnibarRules.clamped(entry.selection, length: OmnibarRules.length(entry.text)),
                suppressCompletion: true
            )
            refreshSuggestions()
        }
    }
}
