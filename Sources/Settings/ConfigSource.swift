import Foundation
import CmuxFoundation

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
            ?? CmuxGhosttyConfigPathResolver().configDirectoryURL(
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
        CmuxGhosttyConfigPathResolver().activeOrEditableConfigURL(
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

    func materializedGhosttySettingsEditorURLs() throws -> [URL] {
        let cmuxURL = try materializeCmuxConfigFileIfNeeded()

        var collector = GhosttySettingsConfigFileCollector(
            fileManager: fileManager,
            homeDirectoryURL: homeDirectoryURL
        )
        collector.append(cmuxURL)

        for url in standaloneGhosttyDisplayCandidates where isRegularFile(at: url) {
            collector.append(url)
        }

        for url in CmuxGhosttyConfigPathResolver().loadConfigURLs(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectoryURL,
            fileManager: fileManager
        ) {
            collector.append(url)
        }

        collector.appendRecursiveConfigFileIncludes()
        return collector.urls
    }

    func writeCmuxConfigContents(_ contents: String) throws {
        let url = cmuxConfigURL
        try writeCmuxConfigContents(contents, to: url)
    }

    func writeCmuxConfigSetting(key: String, value: String) throws {
        let url = try materializeCmuxConfigFileIfNeeded()
        try CmuxGhosttyConfigSettingEditor().writeSetting(
            key: key,
            value: value,
            to: url,
            fileManager: fileManager
        )
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
                cmuxURLs: CmuxGhosttyConfigPathResolver().loadConfigURLs(
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

private struct GhosttySettingsConfigFileCollector {
    let fileManager: FileManager
    let homeDirectoryURL: URL
    private(set) var urls: [URL] = []
    private var seenCanonicalPaths: Set<String> = []

    init(fileManager: FileManager, homeDirectoryURL: URL) {
        self.fileManager = fileManager
        self.homeDirectoryURL = homeDirectoryURL
    }

    mutating func append(_ url: URL) {
        let standardized = url.standardizedFileURL
        let canonicalPath = standardized.resolvingSymlinksInPath().path
        guard seenCanonicalPaths.insert(canonicalPath).inserted else { return }
        urls.append(standardized)
    }

    mutating func appendRecursiveConfigFileIncludes() {
        var queue = urls
        var scannedCanonicalPaths: Set<String> = []

        while !queue.isEmpty {
            let url = queue.removeFirst()
            let canonicalPath = url.resolvingSymlinksInPath().path
            guard scannedCanonicalPaths.insert(canonicalPath).inserted else { continue }
            guard isRegularFile(at: url),
                  let contents = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }

            for includeURL in Self.configFileIncludeURLs(
                in: contents,
                parentDirectoryURL: url.deletingLastPathComponent(),
                homeDirectoryURL: homeDirectoryURL
            ) where isRegularFile(at: includeURL) {
                let beforeCount = urls.count
                append(includeURL)
                if urls.count > beforeCount {
                    queue.append(includeURL)
                }
            }
        }
    }

    private func isRegularFile(at url: URL) -> Bool {
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

    private static func configFileIncludeURLs(
        in contents: String,
        parentDirectoryURL: URL,
        homeDirectoryURL: URL
    ) -> [URL] {
        var urls: [URL] = []
        for line in contents.components(separatedBy: .newlines) {
            guard let entry = parsedGhosttyConfigEntry(from: line),
                  entry.key == "config-file",
                  var value = entry.value else {
                continue
            }
            if !entry.valueWasQuoted {
                value = strippingInlineComment(from: value)
            }

            if value.isEmpty {
                urls.removeAll()
                continue
            }
            if !entry.valueWasQuoted, value.hasPrefix("?") {
                value.removeFirst()
            }
            guard !value.isEmpty else { continue }

            let expandedPath = expandTilde(in: value, homeDirectoryURL: homeDirectoryURL)
            let includeURL: URL
            if (expandedPath as NSString).isAbsolutePath {
                includeURL = URL(fileURLWithPath: expandedPath, isDirectory: false)
            } else {
                includeURL = parentDirectoryURL.appendingPathComponent(expandedPath, isDirectory: false)
            }
            urls.append(includeURL.standardizedFileURL)
        }
        return urls
    }

    private static func strippingInlineComment(from value: String) -> String {
        var result = ""
        var isEscaped = false

        for character in value {
            if isEscaped {
                result.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                result.append(character)
                isEscaped = true
                continue
            }
            if character == "#" {
                break
            }
            result.append(character)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parsedGhosttyConfigEntry(
        from rawLine: String
    ) -> (key: String, value: String?, valueWasQuoted: Bool)? {
        var trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\u{FEFF}") {
            trimmed.removeFirst()
        }
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }

        guard let separatorIndex = trimmed.firstIndex(of: "=") else {
            return (trimmed.trimmingCharacters(in: .whitespacesAndNewlines), nil, false)
        }

        let key = trimmed[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        var value = trimmed[trimmed.index(after: separatorIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let valueWasQuoted = value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")

        if valueWasQuoted {
            value.removeFirst()
            value.removeLast()
        }

        return (String(key), String(value), valueWasQuoted)
    }

    private static func expandTilde(in path: String, homeDirectoryURL: URL) -> String {
        guard path == "~" || path.hasPrefix("~/") else {
            return NSString(string: path).expandingTildeInPath
        }
        let homePath = homeDirectoryURL.path
        if path == "~" {
            return homePath
        }
        return (homePath as NSString).appendingPathComponent(String(path.dropFirst(2)))
    }
}
