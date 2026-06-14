import Foundation

/// The catalog of well-known keyboard-shortcut context keys a ``ShortcutWhenClause``
/// can reference, modeled on VS Code's `when`-clause context keys.
///
/// This enum is the single source of truth for the documented key vocabulary: its
/// raw values are the exact names usable in `shortcuts.when` predicates, and the
/// app target references these cases when populating a ``ShortcutContext`` at key
/// dispatch (so key names never drift between declaration and runtime).
///
/// Unknown keys are still permitted in a clause — ``ShortcutWhenClause/parse(_:)``
/// accepts any bareword and an absent key evaluates to `false`, matching VS Code.
/// This catalog is what tooling (docs, autocomplete) advertises as supported.
///
/// The four focus keys (``sidebarFocus``, ``browserFocus``, ``markdownFocus``,
/// ``terminalFocus``) are also expressed as ``ShortcutFocusAtom`` cases; a clause
/// referencing one of those names parses to ``ShortcutWhenClause/atom(_:)`` rather
/// than ``ShortcutWhenClause/key(_:)`` so existing focus behavior is preserved.
public enum ShortcutContextKnownKey: String, CaseIterable, Sendable {
    /// The right sidebar (vault/files/find/feed/dock) owns focus.
    case sidebarFocus
    /// A browser panel owns focus.
    case browserFocus
    /// A markdown preview viewer owns focus.
    case markdownFocus
    /// A terminal owns focus (no other focus atom holds).
    case terminalFocus
    /// The command palette overlay is visible in the shortcut's window.
    case commandPaletteVisible
    /// The focused terminal's find overlay is open.
    case terminalFindVisible
    /// The right sidebar's active mode (`files`, `find`, `sessions`, `feed`, `dock`).
    case sidebarMode
    /// The number of panes in the focused workspace.
    case paneCount
    /// The number of open workspaces in the focused window.
    case workspaceCount

    /// The static value kind this key carries.
    public var valueType: ShortcutContextValueType {
        switch self {
        case .sidebarFocus, .browserFocus, .markdownFocus, .terminalFocus,
             .commandPaletteVisible, .terminalFindVisible:
            return .bool
        case .sidebarMode:
            return .string
        case .paneCount, .workspaceCount:
            return .int
        }
    }

    /// The finite set of values a string-valued key can take, when known.
    ///
    /// Used by docs/autocomplete to advertise the valid right-hand sides of a
    /// comparison (e.g. `sidebarMode == 'find'`). `nil` for keys whose value range
    /// is open (booleans and integers).
    public var knownStringValues: [String]? {
        switch self {
        case .sidebarMode:
            return ["files", "find", "sessions", "feed", "dock"]
        default:
            return nil
        }
    }
}
