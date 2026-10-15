import Foundation

/// One item of an engine's page context menu: Chromium's menu model, including items that
/// extensions add with `chrome.contextMenus`.
public struct BrowserContextMenuItem: Hashable, Sendable {
    /// How an item behaves in the menu.
    public enum Kind: String, Hashable, Sendable {
        /// A plain command.
        case command
        /// A command with a checkmark.
        case check
        /// One of a group of exclusive choices.
        case radio
        /// A separator line.
        case separator
        /// An item that opens ``BrowserContextMenuItem/children``.
        case submenu
    }

    /// The engine's command id; the host reports it back when the item is chosen.
    public var id: Int
    /// The display title, with `&` mnemonics removed.
    public var title: String
    /// How the item behaves.
    public var kind: Kind
    /// Whether the item can be chosen.
    public var isEnabled: Bool
    /// Whether a check or radio item is on.
    public var isChecked: Bool
    /// A submenu's items.
    public var children: [BrowserContextMenuItem]

    /// Creates an item.
    /// - Parameters:
    ///   - id: The engine's command id.
    ///   - title: The display title.
    ///   - kind: How the item behaves. Defaults to a plain command.
    ///   - isEnabled: Whether it can be chosen. Defaults to `true`.
    ///   - isChecked: Whether a check or radio item is on. Defaults to `false`.
    ///   - children: A submenu's items. Defaults to none.
    public init(
        id: Int,
        title: String,
        kind: Kind = .command,
        isEnabled: Bool = true,
        isChecked: Bool = false,
        children: [BrowserContextMenuItem] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.children = children
    }

    /// Decodes the CEF shim's menu model JSON (the `CMUX_SHIM_CONTEXT_MENU` items list).
    /// - Parameter json: A JSON array of `{id, label, type, enabled, checked, items}` objects.
    /// - Returns: The items, or an empty list for malformed input.
    public static func decodeChromiumList(_ json: String) -> [BrowserContextMenuItem] {
        guard let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([Wire].self, from: data) else {
            return []
        }
        return items.map(\.item)
    }

    /// Removes Chromium's `&` mnemonic markers; `&&` is a literal ampersand.
    /// - Parameter label: A Chromium menu label.
    /// - Returns: The label as shown in an AppKit menu.
    public static func strippingMnemonics(_ label: String) -> String {
        var result = ""
        var iterator = label.makeIterator()
        while let character = iterator.next() {
            if character == "&" {
                if let next = iterator.next() { result.append(next) }
            } else {
                result.append(character)
            }
        }
        return result
    }

    private struct Wire: Decodable {
        var id: Int
        var label: String?
        var type: String?
        var enabled: Bool?
        var checked: Bool?
        var items: [Wire]?

        var item: BrowserContextMenuItem {
            BrowserContextMenuItem(
                id: id,
                title: BrowserContextMenuItem.strippingMnemonics(label ?? ""),
                kind: Kind(rawValue: type ?? "") ?? .command,
                isEnabled: enabled ?? true,
                isChecked: checked ?? false,
                children: (items ?? []).map(\.item)
            )
        }
    }
}
