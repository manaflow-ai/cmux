import Foundation

/// Repository for the preferred editor command, persisted in `UserDefaults`
/// under the catalog's `app.preferredEditor` key.
///
/// Only the stored command lives here; launching the editor is the
/// `CmuxFileOpen` package's `PreferredEditorService`, which reads through
/// ``PreferredEditorReading``.
///
/// Isolation: a stateless `Sendable` struct, not an actor — the single read
/// is synchronous, the struct holds no mutable state, and `UserDefaults` is
/// documented thread-safe.
public struct PreferredEditorSettingsStore: PreferredEditorReading {
    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let keys = AppCatalogSection()

    /// Creates a store reading the given defaults suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var resolvedCommand: String? {
        let stored = keys.preferredEditor.value(in: defaults)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? nil : stored
    }
}
