import Foundation

/// A keyboard-shortcut focus atom — the boolean focus context keys a
/// ``ShortcutWhenClause`` is evaluated against.
///
/// Modeled on VS Code's `when`-clause context keys, scoped to the focus
/// dimensions cmux tracks. Each atom's ``RawValue`` is also a
/// ``ShortcutContextKnownKey`` name, so a clause referencing one of these names
/// parses to ``ShortcutWhenClause/atom(_:)`` and keeps its original behavior.
public enum ShortcutFocusAtom: String, CaseIterable, Sendable {
    /// The right sidebar (vault/files/find/feed/dock) owns focus.
    case sidebarFocus
    /// A browser panel owns focus.
    case browserFocus
    /// A markdown preview viewer owns focus.
    case markdownFocus
    /// A terminal owns focus — i.e. none of the other focus atoms hold.
    case terminalFocus
}
