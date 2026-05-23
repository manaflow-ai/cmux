import AppKit

enum MarkdownPreviewKeyCommand: String, CaseIterable {
    case scrollLeft
    case scrollDown
    case scrollUp
    case scrollRight
    case pageUp
    case pageDown
    case findForward
    case findBackward
    case findNext
    case findPrevious
}

enum MarkdownPreviewKeyboardShortcutResolver {
    typealias ShortcutProvider = (KeyboardShortcutSettings.Action) -> StoredShortcut

    private static let commandActions: [(MarkdownPreviewKeyCommand, KeyboardShortcutSettings.Action)] = [
        (.scrollLeft, .markdownScrollLeft),
        (.scrollDown, .markdownScrollDown),
        (.scrollUp, .markdownScrollUp),
        (.scrollRight, .markdownScrollRight),
        (.pageUp, .markdownPageUp),
        (.pageDown, .markdownPageDown),
        (.findForward, .markdownFindForward),
        (.findBackward, .markdownFindBackward),
        (.findNext, .markdownFindNext),
        (.findPrevious, .markdownFindPrevious),
        (.findNext, .markdownFindNextAlternate),
        (.findPrevious, .markdownFindPreviousAlternate),
    ]

    private static let globalFindCommandActions: [(MarkdownPreviewKeyCommand, KeyboardShortcutSettings.Action)] = [
        (.findForward, .find),
        (.findNext, .findNext),
        (.findPrevious, .findPrevious),
    ]

    private static var singleStrokeCommandActions: [(MarkdownPreviewKeyCommand, KeyboardShortcutSettings.Action)] {
        commandActions + globalFindCommandActions
    }

    static var actions: [KeyboardShortcutSettings.Action] {
        commandActions.map(\.1)
    }

    static func command(
        for event: NSEvent,
        pendingFirstStroke: ShortcutStroke? = nil,
        shortcutForAction: ShortcutProvider = KeyboardShortcutSettings.shortcut(for:)
    ) -> MarkdownPreviewKeyCommand? {
        if let pendingFirstStroke {
            return chordCommand(
                for: event,
                pendingFirstStroke: pendingFirstStroke,
                shortcutForAction: shortcutForAction
            )
        }

        for (command, action) in singleStrokeCommandActions {
            let shortcut = shortcutForAction(action)
            guard !shortcut.hasChord, shortcut.matches(event: event) else { continue }
            return command
        }
        return nil
    }

    static func chordPrefix(
        for event: NSEvent,
        shortcutForAction: ShortcutProvider = KeyboardShortcutSettings.shortcut(for:)
    ) -> ShortcutStroke? {
        for (_, action) in commandActions {
            let shortcut = shortcutForAction(action)
            guard shortcut.hasChord,
                  shortcut.firstStroke.matches(event: event) else { continue }
            return shortcut.firstStroke
        }
        return nil
    }

    private static func chordCommand(
        for event: NSEvent,
        pendingFirstStroke: ShortcutStroke,
        shortcutForAction: ShortcutProvider
    ) -> MarkdownPreviewKeyCommand? {
        for (command, action) in commandActions {
            let shortcut = shortcutForAction(action)
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == pendingFirstStroke,
                  secondStroke.matches(event: event) else { continue }
            return command
        }
        return nil
    }
}
