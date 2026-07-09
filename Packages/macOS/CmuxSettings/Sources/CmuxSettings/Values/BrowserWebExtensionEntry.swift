import Foundation

/// One web extension the user has configured for the built-in browser, stored
/// under `browser.webExtensions` in `cmux.json`.
///
/// Extensions come from two places: Safari web extensions installed on this
/// Mac inside another app's bundle (discovered automatically), and unpacked
/// WebExtension directories the user added by hand. Only entries with
/// ``enabled`` set actually load; discovered-but-untouched extensions have no
/// entry at all.
///
/// ```swift
/// BrowserWebExtensionEntry(
///     id: "com.bitwarden.desktop.safari",
///     kind: .safariAppExtension,
///     path: "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex",
///     enabled: true
/// )
/// ```
public struct BrowserWebExtensionEntry: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Where the extension's resources come from.
    public enum Kind: String, Codable, Sendable {
        /// A Safari web extension `.appex` bundled inside an installed app.
        case safariAppExtension
        /// A directory containing an unpacked WebExtension (`manifest.json` at
        /// its root), Chrome/Firefox load-unpacked style.
        case unpackedDirectory
    }

    /// Stable identity: the appex plug-in identifier for Safari extensions, or
    /// the directory path for unpacked ones.
    public var id: String
    /// Where the extension's resources come from.
    public var kind: Kind
    /// Absolute path to the `.appex` bundle or unpacked directory.
    public var path: String
    /// Whether the extension loads into the browser.
    public var enabled: Bool

    /// - Parameters:
    ///   - id: Stable identity (appex plug-in identifier, or directory path).
    ///   - kind: Where the extension's resources come from.
    ///   - path: Absolute path to the `.appex` bundle or unpacked directory.
    ///   - enabled: Whether the extension loads into the browser.
    public init(id: String, kind: Kind, path: String, enabled: Bool) {
        self.id = id
        self.kind = kind
        self.path = path
        self.enabled = enabled
    }
}

// MARK: - SettingCodable

/// Stored as a nested JSON object; a malformed entry is rejected (decodes to
/// `nil`) rather than partially applied, so bad config fails closed.
extension BrowserWebExtensionEntry: SettingCodable {
    public static func decodeFromUserDefaults(_ raw: Any?) -> BrowserWebExtensionEntry? {
        decodeFromJSON(raw)
    }

    public func encodeForUserDefaults() -> Any {
        encodeForJSON()
    }

    public static func decodeFromJSON(_ raw: Any?) -> BrowserWebExtensionEntry? {
        guard let object = raw as? [String: Any] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(BrowserWebExtensionEntry.self, from: data)
    }

    public func encodeForJSON() -> Any {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return NSNull()
        }
        return object
    }
}
