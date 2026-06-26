public import Foundation

/// A user-defined button on the terminal input-accessory bar.
///
/// Custom actions live alongside the shipped built-in shortcuts and are ordered,
/// shown, and hidden through the same ``TerminalAccessoryLayoutReducer``. Each
/// carries a stable ``id`` (so reordering and per-item enable state survive
/// edits), a short ``title`` for its button face, an optional SF Symbol
/// ``symbolName``, and either a direct ``payload`` or a dropdown menu payload.
///
/// ```swift
/// let launch = CustomToolbarAction(
///     title: "Claude",
///     payload: .text("claude --dangerously-skip-permissions\n")
/// )
/// launch.output // bytes for `claude --dangerously-skip-permissions\r`
/// ```
public struct CustomToolbarAction: Codable, Equatable, Sendable, Identifiable {
    /// Stable identifier, persisted so reorder/enable state tracks the action
    /// across edits.
    public let id: UUID
    /// Short label shown on the button face when ``symbolName`` is `nil`.
    public var title: String
    /// Optional SF Symbol name shown on the button face instead of ``title``.
    public var symbolName: String?
    /// The bytes this action sends when tapped, or the menu it opens.
    public var payload: ToolbarActionPayload

    /// Creates a custom toolbar action.
    /// - Parameters:
    ///   - id: Stable identifier. Defaults to a fresh `UUID`.
    ///   - title: Short label for the button face.
    ///   - symbolName: Optional SF Symbol name shown instead of `title`.
    ///   - payload: The bytes the action sends.
    public init(
        id: UUID = UUID(),
        title: String,
        symbolName: String? = nil,
        payload: ToolbarActionPayload
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.payload = payload
    }

    /// This action's unified identifier in the configurable region.
    public var itemID: ToolbarItemID { .custom(id) }

    /// The bytes sent to the terminal when the button is tapped, or `nil` when
    /// the payload resolves to nothing (empty text, or an unencodable key combo).
    ///
    /// For ``ToolbarActionPayload/text(_:)`` newlines are normalized to carriage
    /// returns, matching the terminal input pipeline's Return handling.
    public var output: Data? {
        switch payload {
        case let .text(value):
            let normalized = value.replacingOccurrences(of: "\n", with: "\r")
            guard !normalized.isEmpty else { return nil }
            return Data(normalized.utf8)
        case let .keyCombo(modifiers, key):
            return TerminalKeyEncoder.encode(specialKey: key, modifiers: modifiers)
        case .menu:
            return nil
        }
    }

    /// Child rows when this action opens a dropdown menu.
    public var menuItems: [ToolbarMenuItem] {
        if case let .menu(items) = payload { return items }
        return []
    }

    /// Whether this action opens a dropdown menu instead of sending bytes
    /// directly.
    public var isMenu: Bool {
        payload.isMenu
    }
}
