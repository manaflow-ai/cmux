import Foundation

/// The static value kind a keyboard-shortcut context key carries.
///
/// Used by ``ShortcutContextKnownKey`` to document each key's type so callers
/// (and docs/autocomplete) know whether a key is a boolean flag, a string-valued
/// mode, or an integer count. It is metadata only — runtime values are carried by
/// ``ShortcutContextValue``.
public enum ShortcutContextValueType: String, CaseIterable, Sendable {
    /// A boolean flag, testable bare (`commandPaletteVisible`) or with `==`/`!=`.
    case bool
    /// A string value, testable with `==`, `!=`, `=~`, or `in`.
    case string
    /// An integer value, testable with `==`, `!=`, and the relational operators.
    case int
}
