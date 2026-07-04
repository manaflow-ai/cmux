import Foundation
import CmuxFoundation

extension CMUXCLI {
    func availableThemeNames() -> [String] {
        let fileManager = FileManager.default
        var seen: Set<String> = []
        var themes: [String] = []

        for directoryURL in themeDirectoryURLs() {
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

    func themeDirectoryURLs() -> [URL] {
        let fileManager = FileManager.default
        let processEnv = ProcessInfo.processInfo.environment
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

        if let resourcesDir = processEnv["GHOSTTY_RESOURCES_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !resourcesDir.isEmpty {
            appendIfExisting(URL(fileURLWithPath: resourcesDir, isDirectory: true).appendingPathComponent("themes", isDirectory: true))
        }

        appendIfExisting(
            Bundle.main.resourceURL?
                .appendingPathComponent("ghostty", isDirectory: true)
                .appendingPathComponent("themes", isDirectory: true)
        )

        if let executableURL = resolvedExecutableURL() {
            var current = executableURL.deletingLastPathComponent().standardizedFileURL
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

                let projectMarker = current.appendingPathComponent("cmux.xcodeproj/project.pbxproj", isDirectory: false)
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

        if let xdgDataDirs = processEnv["XDG_DATA_DIRS"] {
            for dataDir in xdgDataDirs.split(separator: ":").map(String.init).filter({ !$0.isEmpty }) {
                appendIfExisting(
                    homeExpandedURL(dataDir, isDirectory: true)
                        .appendingPathComponent("ghostty/themes", isDirectory: true)
                )
            }
        }

        appendIfExisting(URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes", isDirectory: true))
        appendIfExisting(homeExpandedURL("~/.config/ghostty/themes", isDirectory: true))
        for appSupportDirectory in CmuxApplicationSupportDirectories(environment: processEnv).userDirectories {
            appendIfExisting(
                appSupportDirectory
                    .appendingPathComponent(Self.cmuxThemeOverrideBundleIdentifier, isDirectory: true)
                    .appendingPathComponent("themes", isDirectory: true)
            )
        }
        appendIfExisting(
            homeExpandedURL("~/Library/Application Support/com.mitchellh.ghostty/themes", isDirectory: true)
        )

        return urls
    }

    func validatedThemeName(_ rawValue: String, availableThemes: [String]) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(message: "Theme name cannot be empty")
        }
        if let matched = availableThemes.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return matched
        }
        if availableThemes.isEmpty {
            return trimmed
        }
        throw CLIError(message: "Unknown theme '\(trimmed)'. Run 'cmux themes' to list available themes.")
    }

    func themeConfigSearchURLs(targetBundleIdentifier: String) -> [URL] {
        let fileManager = FileManager.default
        var urls = [
            configURL("~/.config/ghostty/config"),
            configURL("~/.config/ghostty/config.ghostty"),
        ]
        var seen = Set(urls.map { $0.standardizedFileURL.path })

        func append(_ url: URL) {
            let standardized = url.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                urls.append(standardized)
            }
        }

        for appSupportDirectory in CmuxApplicationSupportDirectories(
            environment: ProcessInfo.processInfo.environment
        ).userDirectories {
            let ghosttyDirectory = appSupportDirectory.appendingPathComponent(
                "com.mitchellh.ghostty",
                isDirectory: true
            )
            let legacyGhosttyConfigURL = ghosttyDirectory.appendingPathComponent("config", isDirectory: false)
            let currentGhosttyConfigURL = ghosttyDirectory.appendingPathComponent("config.ghostty", isDirectory: false)

            append(currentGhosttyConfigURL)
            if shouldLoadLegacyGhosttyConfig(
                newConfigURL: currentGhosttyConfigURL,
                legacyConfigURL: legacyGhosttyConfigURL,
                fileManager: fileManager
            ) {
                append(legacyGhosttyConfigURL)
            }

            for url in CmuxGhosttyConfigPathResolver().loadConfigURLs(
                currentBundleIdentifier: targetBundleIdentifier,
                appSupportDirectory: appSupportDirectory,
                fileManager: fileManager
            ) {
                append(url)
            }
        }

        return urls
    }

    private func configURL(_ rawPath: String) -> URL {
        homeExpandedURL(rawPath, isDirectory: false)
    }

    private func homeExpandedURL(_ rawPath: String, isDirectory: Bool) -> URL {
        if rawPath.hasPrefix("~/"),
           let home = ProcessInfo.processInfo.environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !home.isEmpty {
            let relativePath = String(rawPath.dropFirst(2))
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(relativePath, isDirectory: isDirectory)
        }
        return URL(fileURLWithPath: NSString(string: rawPath).expandingTildeInPath, isDirectory: isDirectory)
    }

    private func shouldLoadLegacyGhosttyConfig(
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

    private func configFileSize(at url: URL, fileManager: FileManager) -> Int? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    func lastThemeDirective(in contents: String) -> String? {
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

    func cmuxThemeOverrideConfigURL(targetBundleIdentifier: String) throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CLIError(message: "Failed to locate the Application Support directory")
        }
        return CmuxGhosttyConfigPathResolver().editableConfigURL(
            currentBundleIdentifier: targetBundleIdentifier,
            appSupportDirectory: appSupport
        )
    }

    func writeManagedThemeOverride(
        rawThemeValue: String,
        targetBundleIdentifier: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let configURL = try cmuxThemeOverrideConfigURL(targetBundleIdentifier: targetBundleIdentifier)
        let directoryURL = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        let existingContents = try readOptionalThemeOverrideContents(at: configURL) ?? ""
        let strippedContents = removingManagedThemeOverride(from: existingContents)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let block = """
        \(Self.cmuxThemesBlockStart)
        theme = \(rawThemeValue)
        \(Self.cmuxThemesBlockEnd)
        """

        let nextContents = strippedContents.isEmpty ? "\(block)\n" : "\(strippedContents)\n\n\(block)\n"
        try nextContents.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    func clearManagedThemeOverride(targetBundleIdentifier: String) throws -> URL {
        let fileManager = FileManager.default
        let configURL = try cmuxThemeOverrideConfigURL(targetBundleIdentifier: targetBundleIdentifier)
        guard let existingContents = try readOptionalThemeOverrideContents(at: configURL) else {
            return configURL
        }

        let strippedContents = removingManagedThemeOverride(from: existingContents)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if strippedContents.isEmpty {
            do {
                try fileManager.removeItem(at: configURL)
            } catch {
                guard !isThemeOverrideFileNotFoundError(error) else {
                    return configURL
                }
                throw error
            }
        } else {
            try strippedContents.appending("\n").write(to: configURL, atomically: true, encoding: .utf8)
        }

        return configURL
    }

    private func readOptionalThemeOverrideContents(at url: URL) throws -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            guard isThemeOverrideFileNotFoundError(error) else {
                throw error
            }
            return nil
        }
    }

    private func isThemeOverrideFileNotFoundError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == ENOENT
        }
        return false
    }

    private func removingManagedThemeOverride(from contents: String) -> String {
        let pattern = #"(?ms)\n?# cmux themes start\n.*?\n# cmux themes end\n?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return contents
        }
        let fullRange = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        return regex.stringByReplacingMatches(in: contents, options: [], range: fullRange, withTemplate: "")
    }

    func reloadThemesIfPossible(
        socketPath: String,
        targetBundleIdentifier: String,
        explicitPassword _: String?
    ) -> ThemeReloadStatus {
        DistributedNotificationCenter.default().post(
            name: Notification.Name(Self.cmuxThemesReloadNotificationName),
            object: nil,
            userInfo: [
                "bundleIdentifier": targetBundleIdentifier,
                "socketPath": socketPath,
                "phase": "final",
            ]
        )
        return ThemeReloadStatus(requested: true, targetBundleIdentifier: targetBundleIdentifier)
    }

    func themeTargetBundleIdentifier(socketPath: String) -> String {
        bundleIdentifierForThemeReloadSocketPath(socketPath)
            ?? currentCmuxAppBundleIdentifier()
            ?? Self.cmuxThemeOverrideBundleIdentifier
    }

    private func bundleIdentifierForThemeReloadSocketPath(_ socketPath: String) -> String? {
        let name = URL(fileURLWithPath: socketPath).lastPathComponent
        switch name {
        case "cmux.sock":
            return Self.cmuxThemeOverrideBundleIdentifier
        case "cmux-debug.sock":
            return "com.cmuxterm.app.debug"
        case "cmux-nightly.sock":
            return "com.cmuxterm.app.nightly"
        case "cmux-staging.sock":
            return "com.cmuxterm.app.staging"
        default:
            break
        }

        if name.range(of: #"^cmux-\d+\.sock$"#, options: .regularExpression) != nil {
            return Self.cmuxThemeOverrideBundleIdentifier
        }

        if let slug = themeReloadSocketSlug(name, prefix: "cmux-debug-", suffix: ".sock") {
            return "com.cmuxterm.app.debug.\(slug)"
        }
        if let slug = themeReloadSocketSlug(name, prefix: "cmux-nightly-", suffix: ".sock") {
            return "com.cmuxterm.app.nightly.\(slug)"
        }
        if let slug = themeReloadSocketSlug(name, prefix: "cmux-staging-", suffix: ".sock") {
            return "com.cmuxterm.app.staging.\(slug)"
        }
        return nil
    }

    private func themeReloadSocketSlug(_ name: String, prefix: String, suffix: String) -> String? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else {
            return nil
        }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        let rawSlug = String(name[start..<end])
        let bundleSlug = rawSlug
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: ".", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return bundleSlug.isEmpty ? nil : bundleSlug
    }

    func currentCmuxAppBundleIdentifier() -> String? {
        if let bundleIdentifier = ProcessInfo.processInfo.environment["CMUX_BUNDLE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        if let bundleIdentifier = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        guard let executableURL = resolvedExecutableURL() else {
            return nil
        }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.pathExtension == "app",
               let bundleIdentifier = Bundle(url: current)?.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
               !bundleIdentifier.isEmpty {
                return bundleIdentifier
            }

            if current.lastPathComponent == "Contents" {
                let appURL = current.deletingLastPathComponent().standardizedFileURL
                if appURL.pathExtension == "app",
                   let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !bundleIdentifier.isEmpty {
                    return bundleIdentifier
                }
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        return nil
    }

    func isRightSidebarCLIMode(_ value: String) -> Bool {
        switch value.lowercased() {
        case "files", "find", "vault", "sessions", "feed", "inbox", "dock":
            return true
        default:
            return false
        }
    }

    func normalizedRightSidebarCLIArgument(_ value: String) -> String {
        switch value.lowercased() {
        case "files", "find", "vault", "sessions", "feed", "inbox", "dock":
            return value.lowercased()
        default:
            return value
        }
    }
}
