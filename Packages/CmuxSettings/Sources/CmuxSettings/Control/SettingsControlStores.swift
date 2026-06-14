import Foundation

/// The three persistence backends a catalog setting can route through, bundled
/// for the settings control layer.
///
/// The app constructs this with its live stores (`UserDefaults.standard`, the
/// real `cmux.json`, and the `~/.config/cmux` secret directory) so CLI writes
/// land exactly where the Settings UI reads them and apply live. Tests
/// construct it with an isolated suite, a temp `cmux.json`, and a temp secret
/// directory, so the whole engine is exercised without the app or the socket.
public struct SettingsControlStores: Sendable {
    public let defaults: UserDefaultsSettingsStore
    public let json: JSONConfigStore
    public let secret: SecretFileStore

    public init(
        defaults: UserDefaultsSettingsStore,
        json: JSONConfigStore,
        secret: SecretFileStore
    ) {
        self.defaults = defaults
        self.json = json
        self.secret = secret
    }
}

/// Centralizes the placeholder substituted for secret values so it is impossible
/// for a secret's plaintext to leak through `get` / `list` / `export`.
public enum SettingsRedaction {
    /// The text printed in place of a stored secret. A setting whose secret is
    /// unset prints its (empty) default instead.
    public static let marker = "<redacted>"
}
