import CmuxNextActions
import Foundation

/// Keyboard intents, decoupled from key events so the state machine is
/// testable without AppKit.
public enum PaletteKeyCommand: Equatable, Sendable {
    case moveUp
    case moveDown
    case pageUp
    case pageDown
    case moveToFirst
    case moveToLast
    /// Return: run the primary command (or the selected Actions menu entry).
    case submit
    /// Cmd-Return: run the alternate command.
    case submitAlternate
    /// The footer's Actions button (no default key since decision K1; Tab opens the menu).
    case toggleActions
    /// Tab.
    case openActions
    /// Shift-Tab.
    case closeActions
    /// Esc: close the Actions menu, else pop a page, else clear the query,
    /// else dismiss.
    case escape
    /// Backspace in an empty field: pop a page.
    case back
    /// Right with the caret at the end, on a tree page (`PaletteHierarchy`):
    /// enter the selected row.
    case enterRow
    /// Left in an empty field, on a tree page: go up a level.
    case leaveLevel
    /// Cmd-W: run the selected row's `closeCommand` and keep the palette
    /// open. Not consumed when the row has none.
    case closeItem
    /// Typing while the Actions menu is open filters it.
    case actionsFilterAppend(String)
    case actionsFilterDeleteBackward
}

/// State of the Cmd-K Actions menu for the selected item.
public struct PaletteActionsMenuState {
    public let itemID: String
    public let itemTitle: String
    public let commands: [PaletteCommand]
    public var filter: String = ""
    public var selectedIndex: Int = 0

    /// Commands matching `filter`, in menu order: each word of the filter
    /// is a case- and accent-insensitive subsequence of the title ("cp lnk"
    /// finds Copy Link).
    public var visibleCommands: [PaletteCommand] {
        let words = filter.split(whereSeparator: \.isWhitespace).map { Self.fold($0) }
        guard !words.isEmpty else { return commands }
        return commands.filter { command in
            let title = Self.fold(command.title)
            return words.allSatisfy { word in
                var rest = title[...]
                return word.allSatisfy { char in
                    guard let at = rest.firstIndex(of: char) else { return false }
                    rest = rest[rest.index(after: at)...]
                    return true
                }
            }
        }
    }

    private static func fold(_ text: some StringProtocol) -> String {
        String(text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
