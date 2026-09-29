import Foundation

/// Reads the application used for URLs that cmux intentionally opens outside
/// its embedded browser.
public struct BrowserExternalApplicationSettings {
    /// The `cmux.json` key for the external browser application.
    public static let settingsPath = "browser.externalApplication"

    /// The UserDefaults key mirrored by the settings file store.
    public static let userDefaultsKey = "browserExternalApplication"

    /// An empty value delegates URL handling to macOS Launch Services.
    public static let defaultValue = ""

    private let defaults: UserDefaults

    /// Creates a reader backed by `defaults`.
    ///
    /// - Parameter defaults: The defaults suite that owns browser settings.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Returns the configured bundle identifier, application name, or `.app`
    /// path, or `nil` when macOS should choose the browser.
    public var applicationIdentifier: String? {
        guard let rawValue = defaults.string(forKey: Self.userDefaultsKey) else {
            return nil
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
