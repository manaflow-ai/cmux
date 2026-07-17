import Foundation

/// A Safari web extension found installed on this Mac, as reported by the
/// host through ``SettingsHostActions/discoverBrowserWebExtensions()``.
///
/// This is display metadata only; the persisted setting is
/// `BrowserWebExtensionEntry` in the catalog. `id` matches the entry's `id`
/// (the appex plug-in identifier) so the Browser section can join the two.
public struct SettingsDiscoveredBrowserExtension: Sendable, Identifiable, Equatable {
    /// The appex plug-in identifier (e.g. `com.bitwarden.desktop.safari`).
    public let id: String
    /// Human-readable name resolved from the extension bundle, if available.
    public let displayName: String?
    /// The extension's version string, if available.
    public let version: String?
    /// Absolute path to the `.appex` bundle.
    public let path: String

    /// - Parameters:
    ///   - id: The appex plug-in identifier.
    ///   - displayName: Human-readable name from the extension bundle.
    ///   - version: The extension's version string.
    ///   - path: Absolute path to the `.appex` bundle.
    public init(id: String, displayName: String?, version: String?, path: String) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.path = path
    }
}
