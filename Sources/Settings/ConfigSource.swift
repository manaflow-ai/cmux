import Foundation

struct ConfigSourceEnvironment {
    let homeDirectoryURL: URL
    let previewDirectoryURL: URL
    let fileManager: FileManager

    init(
        homeDirectoryURL: URL,
        previewDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let standardizedHome = homeDirectoryURL.standardizedFileURL
        self.homeDirectoryURL = standardizedHome
        self.fileManager = fileManager
        self.previewDirectoryURL = previewDirectoryURL?.standardizedFileURL
            ?? standardizedHome
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("com.cmuxterm.app", isDirectory: true)
    }

    static func live(fileManager: FileManager = .default) -> Self {
        Self(homeDirectoryURL: fileManager.homeDirectoryForCurrentUser, fileManager: fileManager)
    }

    var cmuxConfigURL: URL {
        applicationSupportDirectoryURL(forBundleIdentifier: "com.cmuxterm.app")
            .appendingPathComponent("config", isDirectory: false)
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
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeRegular
    }

    private func applicationSupportDirectoryURL(forBundleIdentifier bundleIdentifier: String) -> URL {
        homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    private func existingRegularFileURL(in urls: [URL]) -> URL? {
        urls.first(where: isRegularFile(at:))
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
    case ghostty
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
        case .ghostty:
            let url = environment.standaloneGhosttyDisplayURL
            let hasBackingFile = environment.isRegularFile(at: url)
            return ConfigSourceSnapshot(
                source: self,
                primaryURL: url,
                displayPaths: [url.path],
                contents: Self.readContents(at: url),
                isEditable: false,
                hasBackingFile: hasBackingFile,
                hasStandaloneGhosttyConfig: hasBackingFile
            )
        case .synced:
            let ghosttyURL = environment.standaloneGhosttyDisplayURL
            let hasStandaloneGhosttyConfig = environment.isRegularFile(at: ghosttyURL)
            let renderedContents = Self.renderSyncedPreview(
                ghosttyURL: hasStandaloneGhosttyConfig ? ghosttyURL : nil,
                cmuxURL: environment.cmuxConfigURL,
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
        cmuxURL: URL,
        environment: ConfigSourceEnvironment
    ) -> String {
        // Preserve Ghostty key order, then overlay cmux entries using last-wins precedence.
        var effectiveEntriesByKey: [String: ParsedConfigEntry] = [:]
        var orderedKeys: [String] = []

        for sourceURL in [ghosttyURL, cmuxURL].compactMap({ $0 }) {
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
