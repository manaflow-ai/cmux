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
    /// Stable identity: the appex plug-in identifier for Safari extensions, or
    /// the directory path for unpacked ones.
    public var id: String
    /// Where the extension's resources come from.
    public var kind: BrowserWebExtensionKind
    /// Absolute path to the `.appex` bundle or unpacked directory.
    public var path: String
    /// Whether the extension loads into the browser.
    public var enabled: Bool
    /// Human-readable name captured when the extension was imported
    /// (e.g. the containing app's name), shown in the settings list.
    public var displayName: String?
    /// Whether the extension shows a button in the browser toolbar. `nil`
    /// means visible; hiding only affects the button, the extension stays
    /// loaded and its shortcuts keep working.
    public var showsToolbarButton: Bool?

    /// Effective toolbar-button visibility (`showsToolbarButton ?? true`).
    public var effectiveShowsToolbarButton: Bool {
        showsToolbarButton ?? true
    }

    /// - Parameters:
    ///   - id: Stable identity (appex plug-in identifier, or directory path).
    ///   - kind: Where the extension's resources come from.
    ///   - path: Absolute path to the `.appex` bundle or unpacked directory.
    ///   - enabled: Whether the extension loads into the browser.
    ///   - displayName: Human-readable name captured at import time.
    ///   - showsToolbarButton: Toolbar-button visibility (`nil` = visible).
    public init(
        id: String,
        kind: BrowserWebExtensionKind,
        path: String,
        enabled: Bool,
        displayName: String? = nil,
        showsToolbarButton: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.enabled = enabled
        self.displayName = displayName
        self.showsToolbarButton = showsToolbarButton
    }

    /// Absolute, standardized path used to identify the effective extension
    /// resource root for duplicate detection and reconciliation.
    public var standardizedResourceRootPath: String {
        kind.standardizedResourceRootPath(for: path)
    }
}

// MARK: - SettingCodable

/// Stored as a nested JSON object; a malformed entry is rejected (decodes to
/// `nil`) rather than partially applied, so bad config fails closed.
extension BrowserWebExtensionEntry: SettingCodable {
    /// Decodes one extension entry from its UserDefaults-compatible value.
    public static func decodeFromUserDefaults(_ raw: Any?) -> BrowserWebExtensionEntry? {
        decodeFromJSON(raw)
    }

    /// Encodes this entry as a UserDefaults-compatible JSON object.
    public func encodeForUserDefaults() -> Any {
        encodeForJSON()
    }

    /// Decodes one extension entry from a JSON object, failing closed.
    public static func decodeFromJSON(_ raw: Any?) -> BrowserWebExtensionEntry? {
        guard let object = raw as? [String: Any] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(BrowserWebExtensionEntry.self, from: data)
    }

    /// Encodes this entry as a JSON object.
    public func encodeForJSON() -> Any {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return NSNull()
        }
        return object
    }
}
