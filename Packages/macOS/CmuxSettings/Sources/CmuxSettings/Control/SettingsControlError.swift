import Foundation

/// A typed failure from the settings control layer. Carries a human-readable
/// ``message`` the CLI writes to stderr, and maps to a non-zero exit so a write
/// never silently no-ops.
public enum SettingsControlError: Error, Sendable, Equatable {
    /// No catalog entry has this dotted id.
    case unknownKey(String)
    /// The value failed type / enum / range validation for the key.
    case invalidValue(key: String, reason: String)
    /// No keyboard-shortcut action has this id.
    case unknownAction(String)
    /// The key-combo string could not be parsed into a shortcut.
    case invalidShortcut(action: String, reason: String)
    /// The proposed binding already belongs to another action (pass `--force`).
    case shortcutConflict(action: String, conflictingAction: String, binding: String)
    /// An `import` failed validation; nothing was applied. Carries one message
    /// per offending entry so the user can fix them all at once.
    case importFailed(errors: [String])
    /// A backend read/write failed (I/O, permissions, corrupt config).
    case storage(String)
    /// A `UserDefaults`-backed setting is also present in `cmux.json`, whose
    /// managed value the app re-applies on reload — so a UserDefaults write would
    /// be silently overridden. The user must change it in `cmux.json` instead.
    case managedInJSON(key: String)

    /// The message the CLI prints to stderr.
    public var message: String {
        switch self {
        case let .unknownKey(key):
            return "unknown setting '\(key)'. Run 'cmux settings list --keys' to see every key."
        case let .invalidValue(key, reason):
            return "invalid value for '\(key)': \(reason)"
        case let .unknownAction(action):
            return "unknown shortcut action '\(action)'. Run 'cmux settings shortcuts list' to see every action."
        case let .invalidShortcut(action, reason):
            return "invalid shortcut for '\(action)': \(reason)"
        case let .shortcutConflict(action, conflictingAction, binding):
            return "binding '\(binding)' for '\(action)' conflicts with '\(conflictingAction)'. Pass --force to reassign it."
        case let .importFailed(errors):
            let detail = errors.map { "  - \($0)" }.joined(separator: "\n")
            return "import validation failed; no changes applied:\n\(detail)"
        case let .storage(detail):
            return detail
        case let .managedInJSON(key):
            return "'\(key)' is managed in ~/.config/cmux/cmux.json, which the app re-applies over UserDefaults on reload. Change it in cmux.json instead (it would otherwise be silently overridden)."
        }
    }
}

extension SettingsControlError: CustomStringConvertible, LocalizedError {
    /// So `String(describing:)` (used by the socket worker's error encoder) and
    /// `localizedDescription` both surface the friendly ``message``.
    public var description: String { message }
    public var errorDescription: String? { message }
}
