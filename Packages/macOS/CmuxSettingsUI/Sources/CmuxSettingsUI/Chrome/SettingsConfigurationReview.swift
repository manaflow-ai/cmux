import Foundation

/// Metadata annotation attached to a ``SettingsCardRow`` that
/// describes how the row's value persists.
///
/// Mirrors the legacy enum: tells "Show JSON paths" UIs which
/// dotted cmux.json paths the row writes through, distinguishes
/// rows that are pure UserDefaults (`.settingsOnly`), rows that
/// trigger a one-shot action (`.action`), and rows that only
/// surface in debug builds (`.debugOnly`).
public enum SettingsConfigurationReview: Equatable, Sendable {
    case settingsFile([String])
    case settingsOnly
    case action
    case debugOnly

    public static func json(_ paths: String...) -> Self {
        .settingsFile(paths)
    }

    /// Dotted cmux.json paths this row touches. Empty for
    /// non-settings rows.
    public var paths: [String] {
        if case .settingsFile(let paths) = self { return paths }
        return []
    }
}
