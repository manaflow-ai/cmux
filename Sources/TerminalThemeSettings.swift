import Darwin
import Foundation

enum TerminalThemeMode: Equatable, Hashable {
    case custom
    case named(String)
    case adaptive(light: String, dark: String)

    var rawThemeValue: String? {
        switch self {
        case .custom:
            return nil
        case .named(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .adaptive(let light, let dark):
            return TerminalThemeSettings.encodedThemeValue(light: light, dark: dark)
        }
    }
}

struct TerminalThemeSelection: Equatable {
    let mode: TerminalThemeMode
    let rawValue: String?
    let light: String?
    let dark: String?
    let sourcePath: String?

    static let custom = TerminalThemeSelection(
        mode: .custom,
        rawValue: nil,
        light: nil,
        dark: nil,
        sourcePath: nil
    )
}

enum TerminalThemeSettings {
    static let defaultManagedBundleIdentifier = "com.cmuxterm.app"
    static let managedBlockStart = "# cmux themes start"
    static let managedBlockEnd = "# cmux themes end"

    static func availableThemeNames(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        resolvedExecutableURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> [String] {
        var seen: Set<String> = []
        var themes: [String] = []

        for directoryURL in themeDirectoryURLs(
            environment: environment,
            bundleResourceURL: bundleResourceURL,
            resolvedExecutableURL: resolvedExecutableURL,
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

    static func managedConfigURL(
        appSupportDirectory: URL,
        bundleIdentifier: String = defaultManagedBundleIdentifier
    ) -> URL {
        appSupportDirectory
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)
    }

    static func managedConfigURLs(
        appSupportDirectory: URL,
        bundleIdentifier: String = defaultManagedBundleIdentifier
    ) -> [URL] {
        let directory = appSupportDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true)
        return [
            directory.appendingPathComponent("config", isDirectory: false),
            directory.appendingPathComponent("config.ghostty", isDirectory: false),
        ]
    }

    static func managedConfigURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = defaultManagedBundleIdentifier
    ) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return managedConfigURL(appSupportDirectory: appSupport, bundleIdentifier: bundleIdentifier)
    }

    static func themeConfigSearchURLs(
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        includeLegacyManagedConfig: Bool = true,
        fileManager: FileManager = .default
    ) -> [URL] {
        var urls = [
            configURL("~/.config/ghostty/config"),
            configURL("~/.config/ghostty/config.ghostty"),
        ]

        guard let appSupportDirectory else {
            urls.append(configURL("~/Library/Application Support/com.mitchellh.ghostty/config.ghostty"))
            if includeLegacyManagedConfig {
                urls.append(configURL("~/Library/Application Support/\(defaultManagedBundleIdentifier)/config"))
            }
            urls.append(configURL("~/Library/Application Support/\(defaultManagedBundleIdentifier)/config.ghostty"))
            return urls
        }

        let ghosttyDirectory = appSupportDirectory.appendingPathComponent(
            "com.mitchellh.ghostty",
            isDirectory: true
        )
        let legacyGhosttyConfigURL = ghosttyDirectory.appendingPathComponent("config", isDirectory: false)
        let currentGhosttyConfigURL = ghosttyDirectory.appendingPathComponent("config.ghostty", isDirectory: false)

        urls.append(currentGhosttyConfigURL)
        if shouldLoadLegacyGhosttyConfig(
            newConfigURL: currentGhosttyConfigURL,
            legacyConfigURL: legacyGhosttyConfigURL,
            fileManager: fileManager
        ) {
            urls.append(legacyGhosttyConfigURL)
        }

        if let currentBundleIdentifier,
           !currentBundleIdentifier.isEmpty,
           currentBundleIdentifier != defaultManagedBundleIdentifier {
            let currentManagedURL = managedConfigURL(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: currentBundleIdentifier
            )
            if isNonEmptyRegularFile(currentManagedURL, fileManager: fileManager) {
                if includeLegacyManagedConfig {
                    urls.append(currentManagedURL.deletingLastPathComponent().appendingPathComponent("config"))
                }
                urls.append(currentManagedURL)
            }
        }

        let managedURL = managedConfigURL(appSupportDirectory: appSupportDirectory)
        if includeLegacyManagedConfig {
            urls.append(managedURL.deletingLastPathComponent().appendingPathComponent("config"))
        }
        urls.append(managedURL)
        return urls
    }

    static func currentSelection(
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default
    ) -> TerminalThemeSelection {
        currentSelection(
            configURLs: themeConfigSearchURLs(
                currentBundleIdentifier: currentBundleIdentifier,
                appSupportDirectory: appSupportDirectory,
                fileManager: fileManager
            )
        )
    }

    static func managedSelection(
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        bundleIdentifier: String = defaultManagedBundleIdentifier
    ) -> TerminalThemeSelection {
        guard let appSupportDirectory else { return .custom }
        return currentSelection(
            configURLs: managedConfigURLs(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: bundleIdentifier
            )
        )
    }

    static func currentSelection(configURLs: [URL]) -> TerminalThemeSelection {
        var rawValue: String?
        var sourcePath: String?

        for url in configURLs {
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                  let nextValue = lastThemeDirective(in: contents) else {
                continue
            }
            rawValue = nextValue
            sourcePath = url.path
        }

        return parseSelection(rawValue: rawValue, sourcePath: sourcePath)
    }

    @discardableResult
    static func apply(
        _ mode: TerminalThemeMode,
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        fileManager: FileManager = .default,
        reload: () -> Void = {}
    ) throws -> URL {
        guard let appSupportDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }

        let configURL: URL
        if let rawThemeValue = mode.rawThemeValue {
            configURL = try writeManagedThemeOverride(
                rawThemeValue: rawThemeValue,
                appSupportDirectory: appSupportDirectory,
                fileManager: fileManager
            )
        } else {
            configURL = try clearManagedThemeOverride(
                appSupportDirectory: appSupportDirectory,
                fileManager: fileManager
            )
        }
        reload()
        return configURL
    }

    static func lastThemeDirective(in contents: String) -> String? {
        var lastValue: String?

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            guard parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "theme" else { continue }

            let value = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty {
                lastValue = value
            }
        }

        return lastValue
    }

    static func parseSelection(rawValue: String?, sourcePath: String?) -> TerminalThemeSelection {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            return TerminalThemeSelection(
                mode: .custom,
                rawValue: nil,
                light: nil,
                dark: nil,
                sourcePath: sourcePath
            )
        }

        var fallbackTheme: String?
        var lightTheme: String?
        var darkTheme: String?

        for token in rawValue.split(separator: ",").map(String.init) {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count != 2 {
                if fallbackTheme == nil {
                    fallbackTheme = entry
                }
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "light":
                if lightTheme == nil {
                    lightTheme = value
                }
            case "dark":
                if darkTheme == nil {
                    darkTheme = value
                }
            default:
                if fallbackTheme == nil {
                    fallbackTheme = value
                }
            }
        }

        let resolvedLight = lightTheme ?? fallbackTheme
        let resolvedDark = darkTheme ?? fallbackTheme
        let mode: TerminalThemeMode
        if let lightTheme, let darkTheme, lightTheme.caseInsensitiveCompare(darkTheme) != .orderedSame {
            mode = .adaptive(light: lightTheme, dark: darkTheme)
        } else if let theme = resolvedDark ?? resolvedLight {
            mode = .named(theme)
        } else {
            mode = .custom
        }

        return TerminalThemeSelection(
            mode: mode,
            rawValue: rawValue,
            light: resolvedLight,
            dark: resolvedDark,
            sourcePath: sourcePath
        )
    }

    static func encodedThemeValue(light: String?, dark: String?) -> String? {
        let normalizedLight = light?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDark = dark?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (normalizedLight?.isEmpty == false ? normalizedLight : nil, normalizedDark?.isEmpty == false ? normalizedDark : nil) {
        case let (lightTheme?, darkTheme?):
            if lightTheme.caseInsensitiveCompare(darkTheme) == .orderedSame {
                return lightTheme
            }
            return "light:\(lightTheme),dark:\(darkTheme)"
        case let (lightTheme?, nil):
            return "light:\(lightTheme)"
        case let (nil, darkTheme?):
            return "dark:\(darkTheme)"
        case (nil, nil):
            return nil
        }
    }

    @discardableResult
    static func writeManagedThemeOverride(
        rawThemeValue: String,
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let appSupportDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }
        let configURL = managedConfigURL(appSupportDirectory: appSupportDirectory)
        let directoryURL = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        let existingContents = try readOptionalThemeOverrideContents(at: configURL) ?? ""
        let strippedContents = removingManagedThemeOverride(from: existingContents)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let block = """
        \(managedBlockStart)
        theme = \(rawThemeValue)
        \(managedBlockEnd)
        """

        let nextContents = strippedContents.isEmpty ? "\(block)\n" : "\(strippedContents)\n\n\(block)\n"
        try nextContents.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    @discardableResult
    static func clearManagedThemeOverride(
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let appSupportDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }
        let configURL = managedConfigURL(appSupportDirectory: appSupportDirectory)
        guard let existingContents = try readOptionalThemeOverrideContents(at: configURL) else {
            return configURL
        }

        let strippedContents = removingManagedThemeOverride(from: existingContents)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if strippedContents.isEmpty {
            do {
                try fileManager.removeItem(at: configURL)
            } catch {
                guard isThemeOverrideFileNotFoundError(error) else {
                    throw error
                }
            }
        } else {
            try strippedContents.appending("\n").write(to: configURL, atomically: true, encoding: .utf8)
        }

        return configURL
    }

    static func removingManagedThemeOverride(from contents: String) -> String {
        let pattern = #"(?ms)\n?# cmux themes start\n.*?\n# cmux themes end\n?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return contents
        }
        let fullRange = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        let withoutManagedBlock = regex.stringByReplacingMatches(in: contents, options: [], range: fullRange, withTemplate: "")
        return withoutManagedBlock
            .components(separatedBy: .newlines)
            .filter { !isThemeDirectiveLine($0) }
            .joined(separator: "\n")
    }

    private static func themeDirectoryURLs(
        environment: [String: String],
        bundleResourceURL: URL?,
        resolvedExecutableURL: URL?,
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

        if let resolvedExecutableURL {
            var current = resolvedExecutableURL.deletingLastPathComponent().standardizedFileURL
            while true {
                if current.lastPathComponent == "Resources" {
                    appendIfExisting(
                        current
                            .appendingPathComponent("ghostty", isDirectory: true)
                            .appendingPathComponent("themes", isDirectory: true)
                    )
                }
                if current.lastPathComponent == "Contents" {
                    appendIfExisting(
                        current
                            .appendingPathComponent("Resources", isDirectory: true)
                            .appendingPathComponent("ghostty", isDirectory: true)
                            .appendingPathComponent("themes", isDirectory: true)
                    )
                }

                let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj", isDirectory: false)
                let repoThemes = current.appendingPathComponent("Resources/ghostty/themes", isDirectory: true)
                if fileManager.fileExists(atPath: projectMarker.path),
                   fileManager.fileExists(atPath: repoThemes.path) {
                    appendIfExisting(repoThemes)
                    break
                }

                guard let parent = parentSearchURL(for: current) else { break }
                current = parent
            }
        }

        if let xdgDataDirs = environment["XDG_DATA_DIRS"] {
            for dataDir in xdgDataDirs.split(separator: ":").map(String.init).filter({ !$0.isEmpty }) {
                appendIfExisting(
                    URL(fileURLWithPath: NSString(string: dataDir).expandingTildeInPath, isDirectory: true)
                        .appendingPathComponent("ghostty/themes", isDirectory: true)
                )
            }
        }

        appendIfExisting(URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes", isDirectory: true))
        appendIfExisting(URL(fileURLWithPath: NSString(string: "~/.config/ghostty/themes").expandingTildeInPath, isDirectory: true))
        appendIfExisting(
            URL(
                fileURLWithPath: NSString(
                    string: "~/Library/Application Support/com.mitchellh.ghostty/themes"
                ).expandingTildeInPath,
                isDirectory: true
            )
        )

        return urls
    }

    private static func readOptionalThemeOverrideContents(at url: URL) throws -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            guard isThemeOverrideFileNotFoundError(error) else {
                throw error
            }
            return nil
        }
    }

    private static func isThemeOverrideFileNotFoundError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == ENOENT
        }
        return false
    }

    private static func isThemeDirectiveLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            return false
        }

        let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        return parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "theme"
    }

    private static func configURL(_ rawPath: String) -> URL {
        URL(fileURLWithPath: NSString(string: rawPath).expandingTildeInPath, isDirectory: false)
    }

    private static func shouldLoadLegacyGhosttyConfig(
        newConfigURL: URL,
        legacyConfigURL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let newConfigFileSize = configFileSize(at: newConfigURL, fileManager: fileManager),
              newConfigFileSize == 0 else { return false }
        guard let legacyConfigFileSize = configFileSize(at: legacyConfigURL, fileManager: fileManager),
              legacyConfigFileSize > 0 else { return false }
        return true
    }

    private static func configFileSize(at url: URL, fileManager: FileManager) -> Int? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.intValue
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

    private static func parentSearchURL(for url: URL) -> URL? {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        return parent.path == url.standardizedFileURL.path ? nil : parent
    }
}
