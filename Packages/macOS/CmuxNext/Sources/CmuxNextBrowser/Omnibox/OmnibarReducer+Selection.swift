import Foundation

/// Selection rules: the focusing click, drags and
/// multi-clicks, right-click, select-all, Home, and steady-state elision.
/// References are to chrome/browser/ui/views/omnibox/omnibox_view_views.cc
/// unless noted; plans/cmux-next/focus.md has the rule table.
nonisolated extension OmnibarStep {
    /// How a selection change asks to show the full URL (Chromium
    /// `UnelisionGesture`).
    enum Unelision { case home, mouseRelease, other }

    // MARK: Mouse

    /// `OnMousePressed`: a press that focuses the field (left or right)
    /// selects all on release; a right press selects all at once, because the
    /// macOS context menu opens on the press (`SelectionController::
    /// OnMousePressed`, `PlatformStyle::kSelectAllOnRightClickWhenUnfocused`).
    mutating func fieldMouseDown(_ clicks: Int, _ button: OmnibarInput.MouseButton, word: NSRange?) {
        // The field and then its field editor report the same press.
        if state.mouse?.pressed == true { return }
        let focusing = !state.hasFocus || state.mouse != nil
        if clicks == 1 { state.doubleClickWord = nil }
        var mouse = OmnibarState.Mouse(pressed: true, clickCount: clicks, button: button, selectAllOnRelease: focusing)
        if !focusing, button == .left, clicks == 1, state.phase == .focused, state.elided, isAllSelected {
            mouse.wordAtPress = word
        }
        state.mouse = mouse
        if button == .right, focusing, state.hasFocus, !state.isComposing {
            acceptShownText()
            state.edit.selection = Self.all(state.fieldText)
        }
    }

    /// `OnMouseReleased`: select all after a focusing click that did not
    /// drag a selection of its own; otherwise show the full URL, keeping
    /// what the click or drag selected.
    mutating func fieldMouseUp() {
        guard let mouse = state.mouse else { return }
        state.mouse = nil
        guard state.hasFocus, !state.isComposing else { return }
        if mouse.selectAllOnRelease, state.edit.selection.length == 0 {
            acceptShownText()
            state.edit.selection = Self.all(state.fieldText)
            return
        }
        if state.phase == .focused, state.elided {
            // A double-click unelides at its press (Chromium `kOther`); a
            // single click or drag at its release (`kMouseRelease`).
            let offset = unelide(mouse.clickCount >= 2 ? .other : .mouseRelease)
            if let offset, mouse.clickCount == 1, let word = mouse.wordAtPress {
                state.doubleClickWord = NSRange(location: word.location + offset, length: word.length)
            }
        } else if mouse.clickCount == 2, let word = state.doubleClickWord {
            // crbug.com/40693090: the second press landed in the shifted
            // text; select the word under the first click instead.
            state.edit.selection = OmnibarRules.clamped(word, length: OmnibarRules.length(state.fieldText))
            state.doubleClickWord = nil
        }
    }

    // MARK: Keys

    /// Cmd-A: the field editor's select-all. Select-all never unelides.
    mutating func selectAll() {
        guard state.hasFocus, !state.isComposing else {
            handled = false
            return
        }
        acceptShownText()
        state.edit.selection = Self.all(state.fieldText)
        state.lastEditKind = nil
    }

    /// Cmd-L while focused: `SetFocus(is_user_initiated=true)` unelides
    /// (unless the user typed) and selects all.
    mutating func focusLocation() {
        guard state.hasFocus, !state.isComposing else {
            handled = false
            return
        }
        state.elided = false
        acceptShownText()
        state.edit.selection = Self.all(state.fieldText)
        state.lastEditKind = nil
    }

    /// `HandleKeyEvent` `VKEY_HOME`: unelide even from select-all and go to
    /// the start of the full URL. With nothing to unelide the field editor
    /// handles Home.
    mutating func home(extend: Bool) {
        guard state.hasFocus, !state.isComposing, unelide(.home) != nil else {
            handled = false
            return
        }
        state.edit.selection = extend ? NSRange(location: 0, length: state.edit.selection.upperBound) : NSRange(location: 0, length: 0)
    }

    // MARK: Elision

    /// `UnapplySteadyStateElisions`: shows the full URL and maps the
    /// selection into it. Returns the offset of the elided text inside the
    /// full URL, or nil when nothing changed (select-all, or not elided).
    @discardableResult
    mutating func unelide(_ gesture: Unelision) -> Int? {
        guard state.phase == .focused, state.elided else { return nil }
        let shown = state.fieldText
        let selection = OmnibarRules.clamped(state.edit.selection, length: OmnibarRules.length(shown))
        // "If everything is selected, the user likely does not intend to
        // edit the URL." Home is the exception.
        if isAllSelected, gesture != .home { return nil }
        state.elided = false
        let full = state.permanentText as NSString
        var found = full.range(of: shown)
        // "https://foobar" elides to "foobar/"; search without the slash.
        if found.location == NSNotFound, shown.hasSuffix("/") { found = full.range(of: String(shown.dropLast())) }
        guard found.location != NSNotFound else {
            state.edit.selection = OmnibarRules.clamped(selection, length: full.length)
            return 0
        }
        let offset = found.location
        var start = selection.location
        var end = selection.upperBound
        let selected = (shown as NSString).substring(with: selection)
        if selection.length > 0, gesture == .mouseRelease, !classifiesAsSearch(selected) {
            // A URL-like drag from the start keeps the scheme in the
            // selection: google.com/maps => https://www.google.com/maps.
            if start != 0 { start += offset }
            if end != 0 { end += offset }
        } else {
            start += offset
            end += offset
        }
        state.edit.selection = OmnibarRules.clamped(NSRange(location: start, length: end - start), length: full.length)
        return offset
    }

    /// Chromium `OmniboxViewViews::IsSelectAll`.
    var isAllSelected: Bool {
        let text = state.fieldText
        return !text.isEmpty && OmnibarRules.clamped(state.edit.selection, length: OmnibarRules.length(text)) == Self.all(text)
    }

    private func classifiesAsSearch(_ text: String) -> Bool {
        if case .search? = resolver.destination(for: text) { return true }
        return false
    }

    /// Turns an inline completion or an arrowed row's text into typed text.
    mutating func acceptShownText() {
        guard state.phase == .editing else { return }
        if let selected = state.popup.selected, selected > 0, state.popup.rows.indices.contains(selected) {
            state.edit.userText = state.fieldText
            state.edit.inlineCompletion = ""
            state.edit.suppressCompletion = true
            refreshSuggestions()
        } else if !state.edit.inlineCompletion.isEmpty {
            state.edit.userText += state.edit.inlineCompletion
            state.edit.inlineCompletion = ""
            state.edit.suppressCompletion = true
        }
    }
}
