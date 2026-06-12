import Foundation
import AppKit


// MARK: - Theme Resolution
extension GhosttyConfig {
    mutating func applyCmuxDefaultAppearance(
        environment: [String: String],
        bundleResourceURL: URL?,
        preferredColorScheme: ColorSchemePreference
    ) {
        parse(
            Self.cmuxDefaultThemeConfigContents(
                preferredColorScheme: preferredColorScheme,
                environment: environment,
                bundleResourceURL: bundleResourceURL
            )
        )
    }

    private static func cmuxDefaultThemeName(preferredColorScheme: ColorSchemePreference) -> String {
        switch preferredColorScheme {
        case .light:
            return cmuxDefaultLightThemeName
        case .dark:
            return cmuxDefaultDarkThemeName
        }
    }

    static func cmuxDefaultThemeConfigContents(
        preferredColorScheme: ColorSchemePreference,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL
    ) -> String {
        if let url = cmuxDefaultThemeConfigURL(
            preferredColorScheme: preferredColorScheme,
            environment: environment,
            bundleResourceURL: bundleResourceURL
        ), let contents = try? String(contentsOf: url, encoding: .utf8) {
            return contents
        }

        return cmuxDefaultFallbackConfigContents(preferredColorScheme: preferredColorScheme)
    }

    static func cmuxDefaultThemeConfigURL(
        preferredColorScheme: ColorSchemePreference,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL
    ) -> URL? {
        let themeName = cmuxDefaultThemeName(preferredColorScheme: preferredColorScheme)
        for candidateName in themeNameCandidates(from: themeName) {
            for path in themeSearchPaths(
                forThemeName: candidateName,
                environment: environment,
                bundleResourceURL: bundleResourceURL
            ) where (try? String(contentsOfFile: path, encoding: .utf8)) != nil {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    private static func cmuxDefaultFallbackConfigContents(
        preferredColorScheme: ColorSchemePreference
    ) -> String {
        switch preferredColorScheme {
        case .light:
            return """
            palette = 0=#1a1a1a
            palette = 1=#cc372e
            palette = 2=#26a439
            palette = 3=#cdac08
            palette = 4=#0869cb
            palette = 5=#9647bf
            palette = 6=#479ec2
            palette = 7=#98989d
            palette = 8=#464646
            palette = 9=#ff453a
            palette = 10=#32d74b
            palette = 11=#e5bc00
            palette = 12=#0a84ff
            palette = 13=#bf5af2
            palette = 14=#69c9f2
            palette = 15=#ffffff
            background = #feffff
            foreground = #000000
            cursor-color = #98989d
            cursor-text = #ffffff
            selection-background = #abd8ff
            selection-foreground = #000000
            """
        case .dark:
            return """
            palette = 0=#1a1a1a
            palette = 1=#cc372e
            palette = 2=#26a439
            palette = 3=#cdac08
            palette = 4=#0869cb
            palette = 5=#9647bf
            palette = 6=#479ec2
            palette = 7=#98989d
            palette = 8=#464646
            palette = 9=#ff453a
            palette = 10=#32d74b
            palette = 11=#ffd60a
            palette = 12=#0a84ff
            palette = 13=#bf5af2
            palette = 14=#76d6ff
            palette = 15=#ffffff
            background = #1e1e1e
            foreground = #ffffff
            cursor-color = #98989d
            cursor-text = #ffffff
            selection-background = #3f638b
            selection-foreground = #ffffff
            """
        }
    }

    mutating func loadTheme(_ name: String) {
        loadTheme(
            name,
            environment: ProcessInfo.processInfo.environment,
            bundleResourceURL: Bundle.main.resourceURL
        )
    }

    mutating func loadTheme(
        _ name: String,
        environment: [String: String],
        bundleResourceURL: URL?,
        preferredColorScheme: ColorSchemePreference? = nil
    ) {
        let resolvedThemeName = Self.resolveThemeName(
            from: name,
            preferredColorScheme: preferredColorScheme ?? Self.currentColorSchemePreference()
        )
        let expandedThemePath = NSString(string: resolvedThemeName).expandingTildeInPath
        if (expandedThemePath as NSString).isAbsolutePath,
           let contents = try? String(contentsOfFile: expandedThemePath, encoding: .utf8) {
            parse(contents)
            return
        }

        for candidateName in Self.themeNameCandidates(from: resolvedThemeName) {
            for path in Self.themeSearchPaths(
                forThemeName: candidateName,
                environment: environment,
                bundleResourceURL: bundleResourceURL
            ) {
                if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                    parse(contents)
                    return
                }
            }
        }
    }

    static func currentColorSchemePreference(
        appAppearance _: NSAppearance? = nil,
        defaults: UserDefaults = .standard,
        systemAppearance: AppearanceSettings.SystemAppearance? = nil
    ) -> ColorSchemePreference {
        return AppearanceSettings.terminalColorSchemePreference(defaults: defaults, systemAppearance: systemAppearance)
    }

    static func resolveThemeName(
        from rawThemeValue: String,
        preferredColorScheme: ColorSchemePreference
    ) -> String {
        var fallbackTheme: String?
        var lightTheme: String?
        var darkTheme: String?

        for token in rawThemeValue.split(separator: ",").map(String.init) {
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

        switch preferredColorScheme {
        case .light:
            if let lightTheme {
                return lightTheme
            }
        case .dark:
            if let darkTheme {
                return darkTheme
            }
        }

        if let fallbackTheme {
            return fallbackTheme
        }
        if let darkTheme {
            return darkTheme
        }
        if let lightTheme {
            return lightTheme
        }
        return rawThemeValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func themeValueUsesSameResolvedThemeInBothColorSchemes(_ rawThemeValue: String) -> Bool {
        let lightTheme = resolveThemeName(from: rawThemeValue, preferredColorScheme: .light)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let darkTheme = resolveThemeName(from: rawThemeValue, preferredColorScheme: .dark)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lightTheme.isEmpty, !darkTheme.isEmpty else { return false }
        return lightTheme.caseInsensitiveCompare(darkTheme) == .orderedSame
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

    static func themeNameCandidates(from rawName: String) -> [String] {
        var candidates: [String] = []
        let compatibilityAliasGroups: [[String]] = [
            ["Solarized Light", "iTerm2 Solarized Light"],
            ["Solarized Dark", "iTerm2 Solarized Dark"],
        ]

        func appendCandidate(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !candidates.contains(trimmed) {
                candidates.append(trimmed)
            }

            for group in compatibilityAliasGroups {
                if group.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                    for alias in group where alias.caseInsensitiveCompare(trimmed) != .orderedSame {
                        if !candidates.contains(alias) {
                            candidates.append(alias)
                        }
                    }
                }
            }
        }

        var queue: [String] = [rawName]
        while let current = queue.popLast() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            appendCandidate(trimmed)

            let lower = trimmed.lowercased()
            if lower.hasPrefix("builtin ") {
                let stripped = String(trimmed.dropFirst("builtin ".count))
                appendCandidate(stripped)
                queue.append(stripped)
            }

            if let range = trimmed.range(
                of: #"\s*\(builtin\)\s*$"#,
                options: [.regularExpression, .caseInsensitive]
            ) {
                let stripped = String(trimmed[..<range.lowerBound])
                appendCandidate(stripped)
                queue.append(stripped)
            }
        }

        return candidates
    }

    static func themeSearchPaths(
        forThemeName themeName: String,
        environment: [String: String],
        bundleResourceURL: URL?
    ) -> [String] {
        var paths: [String] = []

        func appendUniquePath(_ path: String?) {
            guard let path else { return }
            let expanded = NSString(string: path).expandingTildeInPath
            guard !expanded.isEmpty else { return }
            if !paths.contains(expanded) {
                paths.append(expanded)
            }
        }

        func appendThemePath(in resourcesRoot: String?) {
            guard let resourcesRoot else { return }
            let expanded = NSString(string: resourcesRoot).expandingTildeInPath
            guard !expanded.isEmpty else { return }
            appendUniquePath(
                URL(fileURLWithPath: expanded)
                    .appendingPathComponent("themes/\(themeName)")
                    .path
            )
        }

        // 1) Explicit resources dir used by the running Ghostty embedding.
        appendThemePath(in: environment["GHOSTTY_RESOURCES_DIR"])

        // 2) App bundle resources.
        appendUniquePath(
            bundleResourceURL?
                .appendingPathComponent("ghostty/themes/\(themeName)")
                .path
        )

        // 3) Data dirs (Ghostty installs themes under share/ghostty/themes).
        if let xdgDataDirs = environment["XDG_DATA_DIRS"] {
            for dataDir in xdgDataDirs.split(separator: ":").map(String.init) {
                guard !dataDir.isEmpty else { continue }
                appendUniquePath(
                    URL(fileURLWithPath: dataDir)
                        .appendingPathComponent("ghostty/themes/\(themeName)")
                        .path
                )
            }
        }

        // 4) Common system/user fallback locations.
        appendUniquePath("/Applications/Ghostty.app/Contents/Resources/ghostty/themes/\(themeName)")
        appendUniquePath("~/.config/ghostty/themes/\(themeName)")
        for appSupportDirectory in CmuxApplicationSupportDirectories.userDirectories(environment: environment) {
            appendUniquePath(
                appSupportDirectory
                    .appendingPathComponent(CmuxGhosttyConfigPathResolver.releaseBundleIdentifier, isDirectory: true)
                    .appendingPathComponent("themes", isDirectory: true)
                    .appendingPathComponent(themeName, isDirectory: false)
                    .path
            )
        }
        appendUniquePath("~/Library/Application Support/com.mitchellh.ghostty/themes/\(themeName)")

        return paths
    }

}
