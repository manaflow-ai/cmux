public import Foundation

/// Resolves which cmux-managed Ghostty config file under Application Support is
/// active for a given bundle identifier, including the release-channel fallback
/// chain (debug/nightly/staging builds read the release config when they have
/// none of their own).
///
/// TRANSITIONAL: faithful lift of the app-target config-path namespace cluster
/// the engine and ``GhosttyConfig`` recurse through. These stateless
/// bundle-id→URL transforms have no natural receiver type; modernization into
/// an instantiated, dependency-injected resolver is deferred to the engine lift.
// lint:allow namespace-type — see TRANSITIONAL note above.
public enum CmuxGhosttyConfigPathResolver {
    /// The bundle identifier of the released cmux app, used as the canonical
    /// config location and the fallback for dev/nightly/staging channels.
    public static let releaseBundleIdentifier = "com.cmuxterm.app"
    private static let releaseFallbackChannelSuffixes = ["debug", "nightly", "staging"]

    /// The path cmux writes edits to: always `config.ghostty` under the active
    /// bundle's Application Support directory.
    public static func editableConfigURL(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL
    ) -> URL {
        configDirectoryURL(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory
        )
        .appendingPathComponent("config.ghostty", isDirectory: false)
    }

    /// The currently active config URL if one exists on disk, otherwise the
    /// editable target that a first write should create.
    public static func activeOrEditableConfigURL(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        loadConfigURLs(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory,
            fileManager: fileManager
        )
        .first
        ?? editableConfigURL(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory
        )
    }

    /// The ordered list of cmux-managed config files to load, applying the
    /// release-channel fallback when the current bundle has none of its own.
    public static func loadConfigURLs(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let currentBundleIdentifier, !currentBundleIdentifier.isEmpty else {
            return preferredExistingConfigURLs(
                for: releaseBundleIdentifier,
                appSupportDirectory: appSupportDirectory,
                fileManager: fileManager
            )
        }

        let currentURLs = preferredExistingConfigURLs(
            for: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory,
            fileManager: fileManager
        )
        if !currentURLs.isEmpty {
            return currentURLs
        }
        if allowsReleaseFallback(currentBundleIdentifier) {
            let releaseURLs = preferredExistingConfigURLs(
                for: releaseBundleIdentifier,
                appSupportDirectory: appSupportDirectory,
                fileManager: fileManager
            )
            if !releaseURLs.isEmpty {
                return releaseURLs
            }
        }
        return []
    }

    /// The Application Support directory that holds the config files for a bundle.
    public static func configDirectoryURL(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL
    ) -> URL {
        guard let currentBundleIdentifier, !currentBundleIdentifier.isEmpty else {
            return appSupportDirectory.appendingPathComponent(releaseBundleIdentifier, isDirectory: true)
        }
        return appSupportDirectory.appendingPathComponent(currentBundleIdentifier, isDirectory: true)
    }

    private static func preferredExistingConfigURLs(
        for bundleIdentifier: String,
        appSupportDirectory: URL,
        fileManager: FileManager
    ) -> [URL] {
        let directory = appSupportDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true)
        let legacyConfig = directory.appendingPathComponent("config", isDirectory: false)
        let configGhostty = directory.appendingPathComponent("config.ghostty", isDirectory: false)
        if isNonEmptyConfigFile(configGhostty, fileManager: fileManager) {
            // Do not layer legacy config under config.ghostty. Older builds wrote
            // explicit dark colors there, which blocks appearance-driven themes.
            return [configGhostty]
        }
        if isNonEmptyConfigFile(legacyConfig, fileManager: fileManager) {
            return [legacyConfig]
        }
        return []
    }

    private static func isNonEmptyConfigFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }

        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return isNonEmptySymlinkTarget(url, fileManager: fileManager)
        }

        return isNonEmptyRegularFile(url, fileManager: fileManager)
    }

    private static func isNonEmptySymlinkTarget(_ url: URL, fileManager: FileManager) -> Bool {
        isNonEmptyRegularFile(url.resolvingSymlinksInPath(), fileManager: fileManager)
    }

    private static func isNonEmptyRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeRegular,
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    private static func allowsReleaseFallback(_ bundleIdentifier: String) -> Bool {
        releaseFallbackChannelSuffixes.contains { channelSuffix in
            matchesChannelBundleIdentifier(bundleIdentifier, channelSuffix: channelSuffix)
        }
    }

    private static func matchesChannelBundleIdentifier(
        _ bundleIdentifier: String,
        channelSuffix: String
    ) -> Bool {
        let channelBundleIdentifier = "\(releaseBundleIdentifier).\(channelSuffix)"
        return bundleIdentifier == channelBundleIdentifier
            || bundleIdentifier.hasPrefix("\(channelBundleIdentifier).")
    }
}
