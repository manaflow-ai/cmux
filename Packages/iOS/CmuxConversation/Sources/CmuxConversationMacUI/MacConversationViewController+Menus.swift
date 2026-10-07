#if os(macOS)
import AppKit
import CmuxConversationCore

/// The conversation's share of Messages' menu bar: Format (styles and Text
/// Effects on the composer) and Edit > Search > Find Next / Find Previous.
extension MacConversationViewController {
    /// Format commands act on the draft while the message field has focus,
    /// as Messages' Format menu does.
    var composerIsFocused: Bool { view.window?.firstResponder === composer.textView }

    static let showDetailsAction = NSSelectorFromString("toggleConversationDetails:")
    private static let showingDetailsKey = "isShowingConversationDetails"

    /// Updates the menu-bar items this controller answers (checkmarks and
    /// toggled titles); called from `validateMenuItem`.
    func updateMenuState(_ menuItem: NSMenuItem) {
        guard let action = menuItem.action else { return }
        switch action {
        case #selector(toggleTextStyle(_:)):
            menuItem.state = composer.textView.activeStyle.contains(ConversationTextStyle(rawValue: menuItem.tag)) ? .on : .off
        case #selector(applyTextEffect(_:)):
            let effects = ConversationTextEffect.allCases
            let effect = effects.indices.contains(menuItem.tag) ? effects[menuItem.tag] : nil
            menuItem.state = effect != nil && composer.textView.activeEffect == effect ? .on : .off
        case Self.showDetailsAction:
            // The details panel (its own branch) reports whether it is open.
            if responds(to: NSSelectorFromString(Self.showingDetailsKey)), let showing = value(forKey: Self.showingDetailsKey) as? Bool {
                menuItem.title = showing
                    ? String(localized: "conversation.command.hideDetails", defaultValue: "Hide Details", bundle: .module)
                    : MacConversationCommands.showDetails.title()
            }
        default: break
        }
    }

    // MARK: Format

    /// Format > Bold / Italic / Underline / Strikethrough (tag: the style).
    @objc func toggleTextStyle(_ sender: Any?) {
        guard let tag = (sender as? any NSValidatedUserInterfaceItem)?.tag, tag != 0 else { return NSSound.beep() }
        composer.textView.toggle(ConversationTextStyle(rawValue: tag))
    }

    /// Format > Text Effects (⌥⌘1 Big … ⌥⌘8 Jitter; tag: the effect's index):
    /// the composer's selection, or the whole draft at a caret.
    @objc func applyTextEffect(_ sender: Any?) {
        let effects = ConversationTextEffect.allCases
        guard let tag = (sender as? any NSValidatedUserInterfaceItem)?.tag, effects.indices.contains(tag) else { return NSSound.beep() }
        composer.textView.toggle(effects[tag])
    }

    // MARK: Find Next / Find Previous

    /// Every occurrence of `query` in the loaded transcript, oldest first,
    /// as ranges into each bubble's displayed text.
    func findMatches(_ query: String) -> [(rowID: String, range: NSRange)] {
        guard !query.isEmpty else { return [] }
        var matches: [(rowID: String, range: NSRange)] = []
        for index in rows.indices {
            guard let model = messageModel(at: index) else { continue }
            let text = layoutCache.text(model).string as NSString
            var searchRange = NSRange(location: 0, length: text.length)
            while searchRange.length > 0 {
                let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                guard found.location != NSNotFound, found.length > 0 else { break }
                matches.append((model.rowID, found))
                let next = NSMaxRange(found)
                searchRange = NSRange(location: next, length: text.length - next)
            }
        }
        return matches
    }

    /// Moves to the next (or previous) match of `query`, scrolls it into view
    /// and highlights it. The first search starts at the newest match; the
    /// walk wraps at both ends. Returns false when nothing matches.
    @discardableResult
    func findMatch(_ query: String, forward: Bool) -> Bool {
        let matches = findMatches(query)
        guard !matches.isEmpty else {
            setFindMatch(nil)
            return false
        }
        var next = matches.count - 1
        if let current = keyboard.findMatch, keyboard.findQuery == query,
           let position = matches.firstIndex(where: { $0.rowID == current.rowID && $0.range == current.range }) {
            next = (position + (forward ? 1 : -1) + matches.count) % matches.count
        }
        keyboard.findQuery = query
        setFindMatch(matches[next])
        if let index = rows.firstIndex(where: { $0.id == matches[next].rowID }) {
            tableView.scrollRowToVisible(index)
            view.layoutSubtreeIfNeeded()
            if let row = rowView(at: index), row.window?.isVisible == true {
                row.textLabel.showFindIndicator(for: matches[next].range)
            }
        }
        return true
    }

    func clearFindHighlight() {
        keyboard.findQuery = nil
        setFindMatch(nil)
    }

    private func setFindMatch(_ match: (rowID: String, range: NSRange)?) {
        keyboard.findMatch = match
        tableView.enumerateAvailableRowViews { rowView, _ in
            if let row = (rowView.view(atColumn: 0) as? MacMessageContainerView)?.row { applyFindHighlight(to: row) }
        }
    }

    /// Paints the current find match on `row` (rows are reused, so every
    /// configure clears a stale one).
    func applyFindHighlight(to row: MacMessageRowView) {
        guard let match = keyboard.findMatch, match.rowID == row.model?.rowID else {
            row.textLabel.findHighlightRange = nil
            return
        }
        row.textLabel.findHighlightRange = match.range
    }
}
#endif
