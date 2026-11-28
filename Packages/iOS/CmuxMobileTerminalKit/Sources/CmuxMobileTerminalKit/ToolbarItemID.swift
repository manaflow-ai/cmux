public import Foundation

/// Stable identity of one item in the terminal input-accessory bar's
/// configurable region.
///
/// The bar mixes two kinds of configurable item: the shipped built-in shortcuts
/// (Esc, Tab, arrows, the agent launchers, …), keyed by their enum `rawValue`,
/// and user-defined ``CustomToolbarAction``s, keyed by a stable `UUID`. This
/// type unifies both so a single ``TerminalAccessoryLayoutReducer`` orders,
/// shows, hides, and reorders them together.
///
/// ``storageKey`` is the flat string form persisted in `UserDefaults`
/// (`"builtin.7"`, `"custom.<uuid>"`); ``init(storageKey:)`` parses it back.
public enum ToolbarItemID: Hashable, Sendable, Codable {
    /// A shipped built-in shortcut, identified by its accessory-action `rawValue`.
    case builtin(Int)
    /// A user-defined custom action, identified by its stable id.
    case custom(UUID)

    private static let builtinPrefix = "builtin."
    private static let customPrefix = "custom."

    /// The flat string form persisted in `UserDefaults` and used as the reducer's
    /// identifier in storage (e.g. `"builtin.7"` or `"custom.<uuid>"`).
    public var storageKey: String {
        switch self {
        case let .builtin(rawValue):
            return "\(Self.builtinPrefix)\(rawValue)"
        case let .custom(id):
            return "\(Self.customPrefix)\(id.uuidString)"
        }
    }

    /// Parses a ``storageKey`` back into an identifier.
    ///
    /// - Parameter storageKey: A string produced by ``storageKey``.
    /// - Returns: The decoded identifier, or `nil` if the string is malformed.
    public init?(storageKey: String) {
        if storageKey.hasPrefix(Self.builtinPrefix),
           let rawValue = Int(storageKey.dropFirst(Self.builtinPrefix.count)) {
            self = .builtin(rawValue)
            return
        }
        if storageKey.hasPrefix(Self.customPrefix),
           let id = UUID(uuidString: String(storageKey.dropFirst(Self.customPrefix.count))) {
            self = .custom(id)
            return
        }
        return nil
    }
}
