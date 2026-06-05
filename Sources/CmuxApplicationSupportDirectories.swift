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

enum CmuxGhosttyConfigSettingEditor {
    static let sidebarFontSizeKey = "sidebar-font-size"
    static let defaultSidebarFontSize = 12.5
    static let minSidebarFontSize = 10.0
    static let maxSidebarFontSize = 20.0

    static let surfaceTabBarFontSizeKey = "surface-tab-bar-font-size"
    static let defaultSurfaceTabBarFontSize = 11.0
    static let minSurfaceTabBarFontSize = 8.0
    static let maxSurfaceTabBarFontSize = 14.0

    static func clampedSidebarFontSize(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSidebarFontSize }
        return min(max(value, minSidebarFontSize), maxSidebarFontSize)
    }

    static func formattedSidebarFontSize(_ value: Double) -> String {
        formattedFontSize(clampedSidebarFontSize(value))
    }

    static func parsedSidebarFontSize(in contents: String) -> Double? {
        parsedFontSize(in: contents, key: sidebarFontSizeKey, clamp: clampedSidebarFontSize)
    }

    static func clampedSurfaceTabBarFontSize(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSurfaceTabBarFontSize }
        return min(max(value, minSurfaceTabBarFontSize), maxSurfaceTabBarFontSize)
    }

    static func formattedSurfaceTabBarFontSize(_ value: Double) -> String {
        formattedFontSize(clampedSurfaceTabBarFontSize(value))
    }

    static func parsedSurfaceTabBarFontSize(in contents: String) -> Double? {
        parsedFontSize(in: contents, key: surfaceTabBarFontSizeKey, clamp: clampedSurfaceTabBarFontSize)
    }

    /// Formats a point size for display, trimming trailing zeros (`12`, `13.5`, `13.75`).
    static func formattedFontSize(_ value: Double) -> String {
        let scaled = Int((value * 100).rounded())
        let whole = scaled / 100
        let fraction = abs(scaled % 100)
        if fraction == 0 {
            return "\(whole)"
        }
        if fraction % 10 == 0 {
            return "\(whole).\(fraction / 10)"
        }
        return "\(whole).\(fraction < 10 ? "0" : "")\(fraction)"
    }

    /// Reads the last occurrence of `key` from a Ghostty config body and clamps it to the setting's range.
    private static func parsedFontSize(
        in contents: String,
        key: String,
        clamp: (Double) -> Double
    ) -> Double? {
        guard let rawValue = parsedValue(for: key, in: contents) else {
            return nil
        }
        let unquoted = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard let value = Double(unquoted), value.isFinite else {
            return nil
        }
        return clamp(value)
    }

    static func parsedValue(for key: String, in contents: String) -> String? {
        var latestValue: String?
        for line in contents.components(separatedBy: .newlines) {
            guard let setting = parsedSetting(in: line), setting.key == key else {
                continue
            }
            latestValue = setting.value
        }
        return latestValue
    }

    static func updatedContents(_ contents: String, setting key: String, value: String) -> String {
        var lines = contents.components(separatedBy: "\n")
        if contents.hasSuffix("\n") {
            lines.removeLast()
        }
        if lines.count == 1, lines[0].isEmpty {
            lines = []
        }

        var didReplace = false
        for index in lines.indices {
            guard parsedSetting(in: lines[index])?.key == key else {
                continue
            }
            lines[index] = "\(key) = \(value)"
            didReplace = true
        }

        if !didReplace {
            lines.append("\(key) = \(value)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func writeSetting(
        key: String,
        value: String,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        let writeURL = configWriteURL(for: url, fileManager: fileManager)
        let contents = (try? String(contentsOf: writeURL, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .utf8))
            ?? ""
        let updated = updatedContents(contents, setting: key, value: value)
        try fileManager.createDirectory(
            at: writeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try updated.write(to: writeURL, atomically: true, encoding: .utf8)
    }

    private static func parsedSetting(in line: String) -> (key: String, value: String)? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        // Strip a leading UTF-8 BOM so a BOM-encoded first line still matches its
        // key (otherwise the setting reads as absent and a duplicate is appended).
        if trimmed.hasPrefix("\u{FEFF}") {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        }
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
        let valueStart = trimmed.index(after: separator)
        let value = trimmed[valueStart...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private static func configWriteURL(for url: URL, fileManager: FileManager) -> URL {
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
