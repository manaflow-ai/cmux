import Foundation

/// A typed value held by a keyboard-shortcut context key.
///
/// A ``ShortcutContext`` maps context-key names (e.g. `commandPaletteVisible`,
/// `sidebarMode`, `paneCount`) to these values. The three cases mirror the value
/// kinds a ``ShortcutWhenClause`` can test: boolean focus/visibility flags,
/// string-valued modes, and integer counts.
///
/// ```swift
/// var context = ShortcutContext()
/// context.setBool("commandPaletteVisible", true)
/// context.setString("sidebarMode", "find")
/// context.setInt("paneCount", 2)
/// ```
public enum ShortcutContextValue: Equatable, Sendable {
    /// A boolean flag, such as `commandPaletteVisible`.
    case bool(Bool)
    /// A string value, such as the sidebar's active mode.
    case string(String)
    /// An integer value, such as the number of panes in the focused workspace.
    case int(Int)

    /// The wrapped boolean, or `nil` when the value is not a ``bool(_:)``.
    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    /// The wrapped string, or `nil` when the value is not a ``string(_:)``.
    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// The wrapped integer, or `nil` when the value is not an ``int(_:)``.
    public var intValue: Int? {
        if case let .int(value) = self { return value }
        return nil
    }
}
