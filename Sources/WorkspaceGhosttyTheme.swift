import Foundation

struct WorkspaceGhosttyThemeSelection: Codable, Equatable, Sendable {
    var light: String?
    var dark: String?

    init(light: String? = nil, dark: String? = nil) {
        self.light = Self.normalizedThemeName(light)
        self.dark = Self.normalizedThemeName(dark)
    }

    var isEmpty: Bool {
        light == nil && dark == nil
    }

    var rawValue: String? {
        let trimmedLight = Self.normalizedThemeName(light)
        let trimmedDark = Self.normalizedThemeName(dark)

        switch (trimmedLight, trimmedDark) {
        case let (light?, dark?) where light.caseInsensitiveCompare(dark) == .orderedSame:
            return light
        case let (light?, dark?):
            return "light:\(light),dark:\(dark)"
        case let (light?, nil):
            return light
        case let (nil, dark?):
            return dark
        case (nil, nil):
            return nil
        }
    }

    var displayName: String? {
        switch (light, dark) {
        case let (light?, dark?) where light.caseInsensitiveCompare(dark) == .orderedSame:
            return light
        case let (light?, dark?):
            return "\(light) / \(dark)"
        case let (light?, nil):
            return light
        case let (nil, dark?):
            return dark
        case (nil, nil):
            return nil
        }
    }

    static func single(_ theme: String) -> WorkspaceGhosttyThemeSelection {
        WorkspaceGhosttyThemeSelection(light: theme, dark: theme)
    }

    static func normalizedThemeName(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func fromRawValue(_ rawValue: String?) -> WorkspaceGhosttyThemeSelection? {
        guard let rawValue = normalizedThemeName(rawValue) else { return nil }

        var fallbackTheme: String?
        var lightTheme: String?
        var darkTheme: String?

        for token in rawValue.split(separator: ",").map(String.init) {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count != 2 {
                fallbackTheme = fallbackTheme ?? entry
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "light":
                lightTheme = lightTheme ?? value
            case "dark":
                darkTheme = darkTheme ?? value
            default:
                fallbackTheme = fallbackTheme ?? value
            }
        }

        let selection = WorkspaceGhosttyThemeSelection(
            light: lightTheme ?? fallbackTheme,
            dark: darkTheme ?? fallbackTheme
        )
        return selection.isEmpty ? nil : selection
    }

    func configContents() -> String? {
        guard let rawValue else { return nil }
        return "theme = \(rawValue)"
    }

    func resolvedGhosttyConfig(
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) -> GhosttyConfig {
        var config = GhosttyConfig.load(preferredColorScheme: preferredColorScheme, useCache: false)
        if let contents = configContents() {
            config.parse(contents, loadingThemesImmediatelyFor: preferredColorScheme)
        }
        return config
    }
}

enum WorkspaceGhosttyThemeCatalog {
    private static let cacheLock = NSLock()
    private static var cachedThemeNames: [String]?

    static func cachedAvailableThemeNames() -> [String] {
        cacheLock.lock()
        if let cachedThemeNames {
            cacheLock.unlock()
            return cachedThemeNames
        }
        cacheLock.unlock()

        let resolved = availableThemeNames()

        cacheLock.lock()
        if let cachedThemeNames {
            cacheLock.unlock()
            return cachedThemeNames
        }
        cachedThemeNames = resolved
        cacheLock.unlock()
        return resolved
    }

    static func invalidateCachedAvailableThemeNames() {
        cacheLock.lock()
        cachedThemeNames = nil
        cacheLock.unlock()
    }

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
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                guard values?.isDirectory != true else { continue }
                guard values?.isRegularFile == true || values?.isRegularFile == nil else { continue }
                let name = entry.lastPathComponent
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
        guard !trimmed.isEmpty else { return nil }
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

        func appendIfExisting(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            guard fileManager.fileExists(atPath: standardized.path) else { return }
            if seen.insert(standardized.path).inserted {
                urls.append(standardized)
            }
        }

        if let resourcesDir = environment["GHOSTTY_RESOURCES_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !resourcesDir.isEmpty {
            appendIfExisting(URL(fileURLWithPath: resourcesDir, isDirectory: true).appendingPathComponent("themes", isDirectory: true))
        }

        appendIfExisting(
            bundleResourceURL?
                .appendingPathComponent("ghostty", isDirectory: true)
                .appendingPathComponent("themes", isDirectory: true)
        )
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
