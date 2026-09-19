import CmuxSettings
import Foundation

/// The existing persisted word-wrap preference, shared by settings and editors.
struct FilePreviewWordWrapSettings {
    private let defaults: UserDefaults
    private static let catalog = FileEditorCatalogSection()

    /// UserDefaults / cmux.json key.
    static var key: String { catalog.wordWrap.userDefaultsKey }

    /// Wrapping is off until enabled by the user.
    static var defaultEnabled: Bool { catalog.wordWrap.defaultValue }

    /// Uses the supplied preference domain so tests can isolate persistence.
    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func isEnabled() -> Bool {
        defaults.object(forKey: Self.key) == nil ? Self.defaultEnabled : defaults.bool(forKey: Self.key)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.key)
    }
}
