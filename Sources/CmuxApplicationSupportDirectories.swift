import Darwin
import Foundation

enum CmuxApplicationSupportDirectories {
    static func userDirectories(
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> [URL] {
        var urls: [URL] = []
        var seen: Set<String> = []

        func append(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                urls.append(standardized)
            }
        }

        append(fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)

        if let fixedHome = environment["CFFIXED_USER_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fixedHome.isEmpty {
            append(
                URL(fileURLWithPath: fixedHome, isDirectory: true)
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            )
        }

        append(
            URL(
                fileURLWithPath: NSString(string: "~/Library/Application Support").expandingTildeInPath,
                isDirectory: true
            )
        )

        return urls
    }
}

enum CmuxGhosttyConfigPathResolver {
    static let releaseBundleIdentifier = "com.cmuxterm.app"
    static let cmuxThemesBlockStart = "# cmux themes start"
    static let cmuxThemesBlockEnd = "# cmux themes end"
    private static let releaseFallbackChannelSuffixes = ["debug", "nightly", "staging"]

    static func editableConfigURL(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL
    ) -> URL {
        configDirectoryURL(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory
        )
        .appendingPathComponent("config.ghostty", isDirectory: false)
    }

    static func activeOrEditableConfigURL(
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

    static func loadConfigURLs(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        loadConfigURLs(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectories: [appSupportDirectory],
            fileManager: fileManager
        )
    }

    static func loadConfigURLs(
        currentBundleIdentifier: String?,
        appSupportDirectories: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let currentBundleIdentifier, !currentBundleIdentifier.isEmpty else {
            return configURLs(
                for: releaseBundleIdentifier,
                appSupportDirectories: appSupportDirectories,
                fileManager: fileManager
            )
        }

        let currentURLs = configURLs(
            for: currentBundleIdentifier,
            appSupportDirectories: appSupportDirectories,
            fileManager: fileManager
        )
        if !currentURLs.isEmpty {
            return currentURLs
        }
        if allowsReleaseFallback(currentBundleIdentifier) {
            for appSupportDirectory in uniqueAppSupportDirectories(appSupportDirectories) {
                _ = try? removeStaleReleaseManagedThemeOverrideIfNeeded(
                    currentBundleIdentifier: currentBundleIdentifier,
                    appSupportDirectory: appSupportDirectory,
                    fileManager: fileManager
                )
            }

            let releaseURLs = configURLs(
                for: releaseBundleIdentifier,
                appSupportDirectories: appSupportDirectories,
                fileManager: fileManager
            )
            if !releaseURLs.isEmpty {
                return releaseURLs
            }
        }
        return []
    }

    static func removeStaleReleaseManagedThemeOverrideBeforeFallbackIfNeeded(
        currentBundleIdentifier: String?,
        appSupportDirectories: [URL],
        fileManager: FileManager = .default
    ) throws {
        guard let currentBundleIdentifier = currentBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              shouldRemoveReleaseManagedThemeOverride(for: currentBundleIdentifier) else {
            return
        }

        let currentURLs = configURLs(
            for: currentBundleIdentifier,
            appSupportDirectories: appSupportDirectories,
            fileManager: fileManager
        )
        guard currentURLs.isEmpty else {
            return
        }

        for appSupportDirectory in uniqueAppSupportDirectories(appSupportDirectories) {
            try removeStaleReleaseManagedThemeOverrideIfNeeded(
                currentBundleIdentifier: currentBundleIdentifier,
                appSupportDirectory: appSupportDirectory,
                fileManager: fileManager
            )
        }
    }

    static func configDirectoryURL(
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

    private static func configURLs(
        for bundleIdentifier: String,
        appSupportDirectories: [URL],
        fileManager: FileManager
    ) -> [URL] {
        var urls: [URL] = []
        var seen: Set<String> = []
        for appSupportDirectory in uniqueAppSupportDirectories(appSupportDirectories) {
            for url in preferredExistingConfigURLs(
                for: bundleIdentifier,
                appSupportDirectory: appSupportDirectory,
                fileManager: fileManager
            ) {
                if seen.insert(url.standardizedFileURL.path).inserted {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    private static func uniqueAppSupportDirectories(_ appSupportDirectories: [URL]) -> [URL] {
        var directories: [URL] = []
        var seen: Set<String> = []
        for appSupportDirectory in appSupportDirectories {
            let standardized = appSupportDirectory.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                directories.append(standardized)
            }
        }
        return directories
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

    @discardableResult
    static func removeStaleReleaseManagedThemeOverrideIfNeeded(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard let currentBundleIdentifier = currentBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              shouldRemoveReleaseManagedThemeOverride(for: currentBundleIdentifier) else {
            return false
        }

        var didRemoveManagedThemeOverride = false
        for releaseConfigURL in releaseManagedThemeOverrideCleanupURLs(appSupportDirectory: appSupportDirectory) {
            guard let existingContents = try readOptionalConfigContents(at: releaseConfigURL) else {
                continue
            }

            let strippedContents = removingManagedThemeOverride(from: existingContents)
            guard strippedContents != existingContents else {
                continue
            }

            try writeConfigContentsAfterRemovingManagedThemeOverride(
                strippedContents,
                to: releaseConfigURL,
                fileManager: fileManager
            )
            didRemoveManagedThemeOverride = true
        }
        return didRemoveManagedThemeOverride
    }

    static func removingManagedThemeOverride(from contents: String) -> String {
        let start = NSRegularExpression.escapedPattern(for: cmuxThemesBlockStart)
        let end = NSRegularExpression.escapedPattern(for: cmuxThemesBlockEnd)
        let pattern = "(?ms)\\n?\(start)\\n.*?\\n\(end)\\n?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return contents
        }
        let fullRange = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        return regex.stringByReplacingMatches(in: contents, options: [], range: fullRange, withTemplate: "")
    }

    private static func releaseManagedThemeOverrideCleanupURLs(appSupportDirectory: URL) -> [URL] {
        let directory = configDirectoryURL(
            currentBundleIdentifier: releaseBundleIdentifier,
            appSupportDirectory: appSupportDirectory
        )
        return [
            directory.appendingPathComponent("config.ghostty", isDirectory: false),
            directory.appendingPathComponent("config", isDirectory: false),
        ]
    }

    private static func writeConfigContentsAfterRemovingManagedThemeOverride(
        _ strippedContents: String,
        to configURL: URL,
        fileManager: FileManager
    ) throws {
        let normalizedContents = strippedContents.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedContents.isEmpty {
            do {
                try fileManager.removeItem(at: configURL)
            } catch {
                guard !isConfigFileNotFoundError(error) else {
                    return
                }
                throw error
            }
        } else {
            try normalizedContents.appending("\n").write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    private static func readOptionalConfigContents(at url: URL) throws -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            guard isConfigFileNotFoundError(error) else {
                throw error
            }
            return nil
        }
    }

    private static func isConfigFileNotFoundError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == ENOENT
        }
        return false
    }

    private static func shouldRemoveReleaseManagedThemeOverride(for bundleIdentifier: String) -> Bool {
        bundleIdentifier != releaseBundleIdentifier && allowsReleaseFallback(bundleIdentifier)
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
