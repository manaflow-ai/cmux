import Foundation

/// The default on-disk locations cmux resolves its settings file from.
///
/// Resolves the primary path (`~/.config/cmux/cmux.json`), the sibling fallback
/// (`~/.config/cmux/settings.json`), and the Application Support fallback
/// (`<app support>/<bundle id>/settings.json`) in one value so callers seed a
/// settings-file store's default paths from a single source. The release bundle
/// identifier is injected as a string (the app resolves it from
/// `CmuxGhosttyConfigPathResolver.releaseBundleIdentifier`) so this value type
/// stays decoupled from the config-path resolver. The `FileManager` is injected
/// for testability and defaults to `.default`, matching the legacy static
/// accessors byte-for-byte.
public struct SettingsFileLocations: Sendable, Equatable {
    /// The primary settings file path, `~/.config/cmux/cmux.json`.
    public let primaryPath: String

    /// The sibling fallback path, `~/.config/cmux/settings.json`.
    public let fallbackPath: String?

    /// The Application Support fallback path,
    /// `<app support>/<release bundle id>/settings.json`, or `nil` when the
    /// Application Support directory cannot be resolved.
    public let applicationSupportFallbackPath: String?

    /// Resolves the default settings-file locations.
    ///
    /// - Parameters:
    ///   - releaseBundleIdentifier: The release bundle identifier used as the
    ///     Application Support subdirectory (the app passes
    ///     `CmuxGhosttyConfigPathResolver.releaseBundleIdentifier`).
    ///   - fileManager: The file manager used to resolve the home and
    ///     Application Support directories. Defaults to `.default`.
    public init(
        releaseBundleIdentifier: String,
        fileManager: FileManager = .default
    ) {
        let home = fileManager.homeDirectoryForCurrentUser.path
        self.primaryPath = (home as NSString).appendingPathComponent(".config/cmux/cmux.json")
        self.fallbackPath = (home as NSString).appendingPathComponent(".config/cmux/settings.json")
        if let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            self.applicationSupportFallbackPath = appSupport
                .appendingPathComponent(releaseBundleIdentifier, isDirectory: true)
                .appendingPathComponent("settings.json", isDirectory: false)
                .path
        } else {
            self.applicationSupportFallbackPath = nil
        }
    }
}
