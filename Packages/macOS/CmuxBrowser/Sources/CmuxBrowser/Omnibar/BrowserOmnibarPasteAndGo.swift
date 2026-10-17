public import AppKit

/// Receives the omnibar's "Paste and Go" / "Paste and Search" row: the omnibar text field, as
/// its field editor's delegate.
@MainActor
public protocol BrowserOmnibarPasteAndGoHandling: AnyObject {
    /// Replaces the omnibar text with `text` and submits it, as Return does.
    /// - Parameter text: The pasted text.
    func omnibarPasteAndGo(_ text: String)
}

/// The omnibar's "Paste and Go" / "Paste and Search" right-click row (Safari's and Chrome's):
/// pastes the pasteboard text and submits it in one step.
///
/// ```swift
/// if let row = BrowserOmnibarPasteAndGo.row(forPasteboardText: NSPasteboard.general.string(forType: .string)) {
///     let menu = BrowserOmnibarPasteAndGo.menu(adding: row, to: baseMenu) { text in submit(text) }
/// }
/// ```
@MainActor
public enum BrowserOmnibarPasteAndGo {
    /// Whether submitting the text loads it as an address or searches for it.
    public enum Kind: Equatable, Sendable {
        /// The text is an address: "Paste and Go".
        case go
        /// The text is a search: "Paste and Search".
        case search
    }

    /// The row for one pasteboard text.
    public struct Row: Equatable, Sendable {
        /// The text the row pastes and submits, on one line.
        public let text: String
        /// Which title the row shows.
        public let kind: Kind

        /// Creates a row.
        /// - Parameters:
        ///   - text: The text to paste and submit.
        ///   - kind: Which title the row shows.
        public init(text: String, kind: Kind) {
            self.text = text
            self.kind = kind
        }
    }

    /// Identifies the row in a menu, so reopening a menu never shows it twice.
    static let itemIdentifier = NSUserInterfaceItemIdentifier("cmux.browser.omnibar.pasteAndGo")

    /// The row for `text`, prepared as a paste into the single-line omnibar.
    /// - Parameters:
    ///   - text: The pasteboard's plain text.
    ///   - resolver: Decides whether the text is an address.
    /// - Returns: The row, or `nil` when there is nothing to paste.
    public static func row(forPasteboardText text: String?, resolver: BrowserURLResolver = BrowserURLResolver()) -> Row? {
        guard let text else { return nil }
        // The single-line field turns pasted line breaks into spaces; wrapped URLs are rejoined.
        let line = resolver.textForPaste(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return Row(text: line, kind: resolver.navigableURL(from: line) == nil ? .search : .go)
    }

    /// The row title.
    /// - Parameter kind: Address or search.
    /// - Returns: The localized title.
    public static func title(for kind: Kind) -> String {
        switch kind {
        case .go:
            String(localized: "browser.omnibar.pasteAndGo", defaultValue: "Paste and Go", bundle: .module)
        case .search:
            String(localized: "browser.omnibar.pasteAndSearch", defaultValue: "Paste and Search", bundle: .module)
        }
    }

    /// A copy of `base` with the row after Paste (or at the end), without any earlier copy of it.
    /// `base` itself is not changed: AppKit shares a text view's default menu.
    /// - Parameters:
    ///   - row: The row to add.
    ///   - base: The field editor's menu.
    ///   - perform: Pastes and submits the row's text.
    /// - Returns: The menu to show.
    public static func menu(adding row: Row, to base: NSMenu, perform: @escaping (String) -> Void) -> NSMenu {
        let menu = (base.copy() as? NSMenu) ?? NSMenu(title: base.title)
        for existing in menu.items where existing.identifier == itemIdentifier {
            menu.removeItem(existing)
        }
        let text = row.text
        let item = BrowserMenuActionTarget.item(title: title(for: row.kind)) { perform(text) }
        item.identifier = itemIdentifier
        let paste = menu.items.firstIndex { $0.action == #selector(NSText.paste(_:)) }
        menu.insertItem(item, at: paste.map { $0 + 1 } ?? menu.items.count)
        return menu
    }
}
