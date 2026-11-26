import CmuxMobileTerminalKit

/// One configurable item resolved to its concrete kind: a shipped built-in
/// shortcut or a user-defined ``CustomToolbarAction``.
///
/// ``TerminalAccessoryConfiguration`` projects its ``ToolbarItemID`` order into
/// these so the UIKit bar builder and the SwiftUI settings editor render
/// built-ins and custom actions through one list without re-deriving identity.
public enum ResolvedToolbarItem: Identifiable, Sendable {
    /// A shipped built-in shortcut.
    case builtin(TerminalInputAccessoryAction)
    /// A user-defined custom action.
    case custom(CustomToolbarAction)

    /// The item's unified identifier.
    public var id: ToolbarItemID {
        switch self {
        case let .builtin(action): return action.itemID
        case let .custom(action): return action.itemID
        }
    }

    /// Whether this is a user-defined custom action (editable / deletable).
    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    /// The underlying custom action, when this item is one.
    public var customAction: CustomToolbarAction? {
        if case let .custom(action) = self { return action }
        return nil
    }

    /// Human-readable name for the settings editor row.
    public var settingsDisplayName: String {
        switch self {
        case let .builtin(action): return action.settingsDisplayName
        case let .custom(action): return action.title
        }
    }
}
