import Foundation

nonisolated enum WorkspaceGhosttyThemeCatalog {
    static func availableThemeNames(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> [String] {
        var seen: Set<String> = []
        var themes: [String] = []

        for directoryURL in themeDirectoryURLs(
            environment: environment,
            bundleResourceURL: bundleResourceURL,
            fileManager: fileManager
        ) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isDirectory != true else { continue }
                guard values?.isRegularFile == true ||
                    values?.isSymbolicLink == true ||
                    values?.isRegularFile == nil else { continue }
                let name = entry.lastPathComponent
                guard isSafeThemeValue(name) else { continue }
                let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if seen.insert(folded).inserted {
                    themes.append(name)
                }
            }
        }

        return themes.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func validatedThemeName(_ rawValue: String, availableThemes: [String]) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeThemeValue(trimmed) else { return nil }
        if trimmed.hasPrefix("/"),
           let url = validAbsoluteThemeURL(trimmed) {
            return url.path
        }
        if let matched = availableThemes.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return matched
        }
        return availableThemes.isEmpty ? trimmed : nil
    }

    private static func themeDirectoryURLs(
        environment: [String: String],
        bundleResourceURL: URL?,
        fileManager: FileManager
    ) -> [URL] {
        var urls: [URL] = []
        var seen: Set<String> = []

        @discardableResult
        func appendIfExisting(_ url: URL?) -> Bool {
            guard let url else { return false }
            let standardized = url.standardizedFileURL
            guard fileManager.fileExists(atPath: standardized.path) else { return false }
            if seen.insert(standardized.path).inserted {
                urls.append(standardized)
                return true
            }
            return false
        }

        let hasBundledThemes = appendIfExisting(
            bundleResourceURL?
                .appendingPathComponent("ghostty", isDirectory: true)
                .appendingPathComponent("themes", isDirectory: true)
        )
        if !hasBundledThemes,
           let resourcesDir = environment["GHOSTTY_RESOURCES_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !resourcesDir.isEmpty {
            appendIfExisting(URL(fileURLWithPath: resourcesDir, isDirectory: true).appendingPathComponent("themes", isDirectory: true))
        }
        if let xdgDataDirs = environment["XDG_DATA_DIRS"] {
            for dataDir in xdgDataDirs.split(separator: ":").map(String.init) {
                let trimmed = dataDir.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                appendIfExisting(
                    URL(fileURLWithPath: trimmed, isDirectory: true)
                        .appendingPathComponent("ghostty", isDirectory: true)
                        .appendingPathComponent("themes", isDirectory: true)
                )
            }
        }
        appendIfExisting(URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes", isDirectory: true))
        appendIfExisting(homeExpandedURL("~/.config/ghostty/themes", environment: environment, isDirectory: true))
        appendIfExisting(homeExpandedURL("~/Library/Application Support/com.mitchellh.ghostty/themes", environment: environment, isDirectory: true))

        for appSupportDirectory in CmuxApplicationSupportDirectories.userDirectories(environment: environment) {
            appendIfExisting(
                appSupportDirectory
                    .appendingPathComponent(CmuxGhosttyConfigPathResolver.releaseBundleIdentifier, isDirectory: true)
                    .appendingPathComponent("themes", isDirectory: true)
            )
        }

        return urls
    }

    private static func isSafeThemeValue(_ rawValue: String) -> Bool {
        !rawValue.isEmpty &&
            rawValue.rangeOfCharacter(from: .newlines) == nil &&
            rawValue.range(of: "\0") == nil
    }

    private static func validAbsoluteThemeURL(_ rawPath: String, fileManager: FileManager = .default) -> URL? {
        let url = URL(fileURLWithPath: rawPath, isDirectory: false).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private static func homeExpandedURL(_ rawPath: String, environment: [String: String], isDirectory: Bool) -> URL {
        if rawPath.hasPrefix("~/"),
           let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(String(rawPath.dropFirst(2)), isDirectory: isDirectory)
        }
        return URL(fileURLWithPath: NSString(string: rawPath).expandingTildeInPath, isDirectory: isDirectory)
    }
}
