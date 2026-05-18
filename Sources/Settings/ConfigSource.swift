import Foundation

struct ConfigSourceEnvironment {
    let homeDirectoryURL: URL
    let previewDirectoryURL: URL
    let fileManager: FileManager
    let currentBundleIdentifier: String?

    init(
        homeDirectoryURL: URL,
        currentBundleIdentifier: String? = CmuxGhosttyConfigPathResolver.releaseBundleIdentifier,
        previewDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let standardizedHome = homeDirectoryURL.standardizedFileURL
        self.homeDirectoryURL = standardizedHome
        self.fileManager = fileManager
        self.currentBundleIdentifier = currentBundleIdentifier
        self.previewDirectoryURL = previewDirectoryURL?.standardizedFileURL
            ?? CmuxGhosttyConfigPathResolver.configDirectoryURL(
                currentBundleIdentifier: currentBundleIdentifier,
                appSupportDirectory: standardizedHome
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Application Support", isDirectory: true)
            )
    }

    static func live(fileManager: FileManager = .default) -> Self {
        Self(
            homeDirectoryURL: fileManager.homeDirectoryForCurrentUser,
            currentBundleIdentifier: Bundle.main.bundleIdentifier,
            fileManager: fileManager
        )
    }

    var cmuxConfigURL: URL {
        CmuxGhosttyConfigPathResolver.activeOrEditableConfigURL(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectoryURL,
            fileManager: fileManager
        )
    }

    var standaloneGhosttyDisplayURL: URL {
        existingRegularFileURL(in: standaloneGhosttyDisplayCandidates) ?? standaloneGhosttyDisplayCandidates[0]
    }

    var standaloneGhosttyDisplayCandidates: [URL] {
        [
            homeDirectoryURL
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("ghostty", isDirectory: true)
                .appendingPathComponent("config", isDirectory: false),
            homeDirectoryURL
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("ghostty", isDirectory: true)
                .appendingPathComponent("config.ghostty", isDirectory: false),
            applicationSupportDirectoryURL(forBundleIdentifier: "com.mitchellh.ghostty")
                .appendingPathComponent("config", isDirectory: false),
            applicationSupportDirectoryURL(forBundleIdentifier: "com.mitchellh.ghostty")
                .appendingPathComponent("config.ghostty", isDirectory: false),
        ]
    }

    var syncedPreviewURL: URL {
        previewDirectoryURL.appendingPathComponent("config.synced-preview", isDirectory: false)
    }

    func materializeCmuxConfigFileIfNeeded() throws -> URL {
        let url = cmuxConfigURL
        guard !fileManager.fileExists(atPath: url.path) else { return url }
        try writeCmuxConfigContents("", to: url)
        return url
    }

    func writeCmuxConfigContents(_ contents: String) throws {
        let url = cmuxConfigURL
        try writeCmuxConfigContents(contents, to: url)
    }

    private func writeCmuxConfigContents(_ contents: String, to url: URL) throws {
        let writeURL = configWriteURL(for: url)
        try fileManager.createDirectory(
            at: writeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try contents.write(to: writeURL, atomically: true, encoding: .utf8)
    }

    func abbreviatedPath(for url: URL) -> String {
        let path = url.path
        let homePath = homeDirectoryURL.path
        if path == homePath {
            return "~"
        }
        let prefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + path.dropFirst(prefix.count)
    }

    func isRegularFile(at url: URL) -> Bool {
        if isDirectRegularFile(at: url) {
            return true
        }
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return false
        }
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = url.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return isDirectRegularFile(at: destinationURL.standardizedFileURL.resolvingSymlinksInPath())
    }

    private func isDirectRegularFile(at url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeRegular
    }

    var appSupportDirectoryURL: URL {
        homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    private func applicationSupportDirectoryURL(forBundleIdentifier bundleIdentifier: String) -> URL {
        appSupportDirectoryURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    private func existingRegularFileURL(in urls: [URL]) -> URL? {
        urls.first(where: isRegularFile(at:))
    }

    private func configWriteURL(for url: URL) -> URL {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return url
        }
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = url.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return destinationURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}

enum CmuxGhosttyConfigPathResolver {
    static let releaseBundleIdentifier = "com.cmuxterm.app"
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

struct ConfigSourceSnapshot {
    let source: ConfigSource
    let primaryURL: URL
    let displayPaths: [String]
    let contents: String
    let isEditable: Bool
    let hasBackingFile: Bool
    let hasStandaloneGhosttyConfig: Bool
}

enum ConfigSource: String, CaseIterable, Identifiable {
    case cmux
    case synced

    var id: Self { self }

    var isEditable: Bool {
        self == .cmux
    }

    func snapshot(environment: ConfigSourceEnvironment = .live()) -> ConfigSourceSnapshot {
        switch self {
        case .cmux:
            let url = environment.cmuxConfigURL
            return ConfigSourceSnapshot(
                source: self,
                primaryURL: url,
                displayPaths: [url.path],
                contents: Self.readContents(at: url),
                isEditable: true,
                hasBackingFile: environment.isRegularFile(at: url),
                hasStandaloneGhosttyConfig: environment.isRegularFile(at: environment.standaloneGhosttyDisplayURL)
            )
        case .synced:
            let ghosttyURL = environment.standaloneGhosttyDisplayURL
            let hasStandaloneGhosttyConfig = environment.isRegularFile(at: ghosttyURL)
            let renderedContents = Self.renderSyncedPreview(
                ghosttyURL: hasStandaloneGhosttyConfig ? ghosttyURL : nil,
                cmuxURLs: CmuxGhosttyConfigPathResolver.loadConfigURLs(
                    currentBundleIdentifier: environment.currentBundleIdentifier,
                    appSupportDirectory: environment.appSupportDirectoryURL,
                    fileManager: environment.fileManager
                ),
                environment: environment
            )
            Self.materializeSyncedPreview(
                contents: renderedContents,
                previewURL: environment.syncedPreviewURL,
                fileManager: environment.fileManager
            )
            return ConfigSourceSnapshot(
                source: self,
                primaryURL: environment.syncedPreviewURL,
                displayPaths: [environment.syncedPreviewURL.path],
                contents: renderedContents,
                isEditable: false,
                hasBackingFile: environment.isRegularFile(at: environment.syncedPreviewURL),
                hasStandaloneGhosttyConfig: hasStandaloneGhosttyConfig
            )
        }
    }

    private static func readContents(at url: URL) -> String {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return contents
    }

    private static func materializeSyncedPreview(
        contents: String,
        previewURL: URL,
        fileManager: FileManager
    ) {
        do {
            try fileManager.createDirectory(
                at: previewURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try contents.write(to: previewURL, atomically: true, encoding: .utf8)
        } catch {
            // Best-effort preview materialization. The in-memory snapshot remains usable.
        }
    }

    private static func renderSyncedPreview(
        ghosttyURL: URL?,
        cmuxURLs: [URL],
        environment: ConfigSourceEnvironment
    ) -> String {
        // Preserve Ghostty key order, then overlay cmux entries using last-wins precedence.
        var effectiveEntriesByKey: [String: ParsedConfigEntry] = [:]
        var orderedKeys: [String] = []

        for sourceURL in ([ghosttyURL].compactMap { $0 } + cmuxURLs) {
            for entry in parsedEntries(from: sourceURL) {
                if effectiveEntriesByKey[entry.key] == nil {
                    orderedKeys.append(entry.key)
                }
                effectiveEntriesByKey[entry.key] = entry
            }
        }

        return orderedKeys.compactMap { key in
            guard let entry = effectiveEntriesByKey[key] else { return nil }
            let sourceLabel = environment.abbreviatedPath(for: entry.sourceURL)
            return "\(entry.key) = \(entry.value)  # from: \(sourceLabel):\(entry.lineNumber)"
        }
        .joined(separator: "\n")
    }

    private static func parsedEntries(from sourceURL: URL) -> [ParsedConfigEntry] {
        let contents = readContents(at: sourceURL)
        guard !contents.isEmpty else { return [] }

        return contents
            .components(separatedBy: .newlines)
            .enumerated()
            .compactMap { index, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                    return nil
                }
                let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return nil }
                return ParsedConfigEntry(
                    key: key,
                    value: value,
                    sourceURL: sourceURL,
                    lineNumber: index + 1
                )
            }
    }
}

private struct ParsedConfigEntry {
    let key: String
    let value: String
    let sourceURL: URL
    let lineNumber: Int
}
