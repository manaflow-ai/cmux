import Foundation
import AppKit


// MARK: - Config Loading
extension GhosttyConfig {
    private static let loadCacheLock = NSLock()
    private static var cachedConfigsByColorScheme: [ColorSchemePreference: GhosttyConfig] = [:]
    static func load(
        preferredColorScheme: ColorSchemePreference? = nil,
        useCache: Bool = true,
        loadFromDisk: (_ preferredColorScheme: ColorSchemePreference) -> GhosttyConfig = Self.loadFromDisk
    ) -> GhosttyConfig {
        let resolvedColorScheme = preferredColorScheme ?? currentColorSchemePreference()
        if useCache, let cached = cachedLoad(for: resolvedColorScheme) {
            return cached
        }

        let loaded = loadFromDisk(resolvedColorScheme)
        if useCache {
            storeCachedLoad(loaded, for: resolvedColorScheme)
        }
        return loaded
    }

    static func invalidateLoadCache() {
        loadCacheLock.lock()
        cachedConfigsByColorScheme.removeAll()
        loadCacheLock.unlock()
    }

    private static func cachedLoad(for colorScheme: ColorSchemePreference) -> GhosttyConfig? {
        loadCacheLock.lock()
        defer { loadCacheLock.unlock() }
        return cachedConfigsByColorScheme[colorScheme]
    }

    private static func storeCachedLoad(
        _ config: GhosttyConfig,
        for colorScheme: ColorSchemePreference
    ) {
        loadCacheLock.lock()
        cachedConfigsByColorScheme[colorScheme] = config
        loadCacheLock.unlock()
    }

    private static func cmuxConfigPaths(
        fileManager: FileManager = .default,
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> [String] {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return []
        }

        return GhosttyApp.cmuxAppSupportConfigURLs(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupport,
            fileManager: fileManager
        ).map(\.path)
    }

    private static func loadFromDisk(preferredColorScheme: ColorSchemePreference) -> GhosttyConfig {
        var config = GhosttyConfig()

        // Match Ghostty's default load order on macOS.
        let appSupportGhosttyDirectory = NSString(
            string: "~/Library/Application Support/com.mitchellh.ghostty"
        ).expandingTildeInPath
        let appSupportConfigGhostty = (appSupportGhosttyDirectory as NSString)
            .appendingPathComponent("config.ghostty")
        let appSupportLegacyConfig = (appSupportGhosttyDirectory as NSString)
            .appendingPathComponent("config")
        var configPaths = [
            "~/.config/ghostty/config",
            "~/.config/ghostty/config.ghostty",
        ].map { NSString(string: $0).expandingTildeInPath }
        configPaths.append(appSupportConfigGhostty)
        if shouldIncludeLegacyGhosttyConfigInResolvedLoad(
            newConfigFileSize: configFileSize(at: appSupportConfigGhostty),
            legacyConfigFileSize: configFileSize(at: appSupportLegacyConfig)
        ) {
            configPaths.append(appSupportLegacyConfig)
        }
        configPaths.append(contentsOf: cmuxConfigPaths())

        #if DEBUG
        let startupPreviewProfile = GhosttyStartupAppearancePreviewState.profile
        if startupPreviewProfile.loadsRealUserConfig {
            loadConfigFiles(
                configPaths,
                into: &config,
                preferredColorScheme: preferredColorScheme
            )

            if config.theme == nil,
               GhosttyApp.shouldApplyManagedDefaultAppearance(configPaths: configPaths) {
                config.applyCmuxDefaultAppearance(
                    environment: ProcessInfo.processInfo.environment,
                    bundleResourceURL: Bundle.main.resourceURL,
                    preferredColorScheme: preferredColorScheme
                )
            }
        } else if let contents = startupPreviewProfile.previewConfigContents(
            preferredColorScheme: preferredColorScheme
        ) {
            config.parse(
                contents,
                loadingThemesImmediatelyFor: preferredColorScheme
            )
        }
        #else
        loadConfigFiles(
            configPaths,
            into: &config,
            preferredColorScheme: preferredColorScheme
        )

        if config.theme == nil,
           GhosttyApp.shouldApplyManagedDefaultAppearance(configPaths: configPaths) {
            config.applyCmuxDefaultAppearance(
                environment: ProcessInfo.processInfo.environment,
                bundleResourceURL: Bundle.main.resourceURL,
                preferredColorScheme: preferredColorScheme
            )
        }
        #endif

        config.resolveSidebarBackground(preferredColorScheme: preferredColorScheme)
        config.applySidebarAppearanceToUserDefaults()

        return config
    }

    private static func loadConfigFiles(
        _ paths: [String],
        into config: inout GhosttyConfig,
        preferredColorScheme: ColorSchemePreference
    ) {
        var recursiveConfigPaths: [String] = []
        var loadedConfigPaths = Set<String>()

        for path in paths.map({ NSString(string: $0).expandingTildeInPath }) {
            loadConfigFile(
                at: path,
                into: &config,
                preferredColorScheme: preferredColorScheme,
                recursiveConfigPaths: &recursiveConfigPaths,
                loadedConfigPaths: &loadedConfigPaths,
                markLoadedPath: false
            )
        }

        while !recursiveConfigPaths.isEmpty {
            let path = recursiveConfigPaths.removeFirst()
            loadConfigFile(
                at: path,
                into: &config,
                preferredColorScheme: preferredColorScheme,
                recursiveConfigPaths: &recursiveConfigPaths,
                loadedConfigPaths: &loadedConfigPaths,
                markLoadedPath: true
            )
        }
    }

    private static func loadConfigFile(
        at path: String,
        into config: inout GhosttyConfig,
        preferredColorScheme: ColorSchemePreference,
        recursiveConfigPaths: inout [String],
        loadedConfigPaths: inout Set<String>,
        markLoadedPath: Bool
    ) {
        let resolved = (path as NSString).standardizingPath
        if markLoadedPath {
            guard !loadedConfigPaths.contains(resolved) else { return }
        }
        guard let contents = readConfigFile(at: resolved) else { return }
        if markLoadedPath {
            loadedConfigPaths.insert(resolved)
        }

        config.parse(
            contents,
            loadingThemesImmediatelyFor: preferredColorScheme
        )

        let parentDir = (resolved as NSString).deletingLastPathComponent
        collectRecursiveConfigPaths(
            from: contents,
            parentDir: parentDir,
            recursiveConfigPaths: &recursiveConfigPaths
        )
    }

    private static func collectRecursiveConfigPaths(
        from contents: String,
        parentDir: String,
        recursiveConfigPaths: inout [String]
    ) {
        for line in contents.components(separatedBy: .newlines) {
            guard let entry = parsedConfigEntry(from: line),
                  entry.key == "config-file" else {
                continue
            }
            guard let value = entry.value else { continue }
            applyConfigFileDirective(
                value,
                valueWasQuoted: entry.valueWasQuoted,
                parentDir: parentDir,
                recursiveConfigPaths: &recursiveConfigPaths
            )
        }
    }

    private static func parsedConfigEntry(
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

    private static func applyConfigFileDirective(
        _ value: String,
        valueWasQuoted: Bool,
        parentDir: String,
        recursiveConfigPaths: inout [String]
    ) {
        if value.isEmpty {
            recursiveConfigPaths.removeAll()
            return
        }

        var includePath = value
        if !valueWasQuoted, includePath.hasPrefix("?") {
            includePath.removeFirst()
            if includePath.count >= 2,
               includePath.hasPrefix("\""),
               includePath.hasSuffix("\"") {
                includePath.removeFirst()
                includePath.removeLast()
            }
        }
        guard !includePath.isEmpty else { return }

        let expanded = NSString(string: includePath).expandingTildeInPath
        let absolute = (expanded as NSString).isAbsolutePath
            ? expanded
            : (parentDir as NSString).appendingPathComponent(expanded)
        recursiveConfigPaths.append(absolute)
    }

    private static func readConfigFile(at path: String) -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return nil }

        if let attributes = try? fileManager.attributesOfItem(atPath: path) {
            if let type = attributes[.type] as? FileAttributeType,
               type != .typeRegular && type != .typeSymbolicLink {
                return nil
            }
            if let size = attributes[.size] as? NSNumber, size.intValue == 0 {
                return nil
            }
        }

        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private static func configFileSize(at path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.intValue
    }

    private static func shouldIncludeLegacyGhosttyConfigInResolvedLoad(
        newConfigFileSize: Int?,
        legacyConfigFileSize: Int?
    ) -> Bool {
        guard let legacyConfigFileSize, legacyConfigFileSize > 0 else { return false }
        guard let newConfigFileSize else { return true }
        return newConfigFileSize == 0
    }
}
