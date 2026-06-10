import Darwin
import Foundation


// MARK: - Diff Viewer Appearance and Ghostty Theme Resolution
extension CMUXCLI {
    func diffViewerAppearance(socketPath: String, fontSizeOverride: Double?) -> DiffViewerAppearance {
        var appearance = defaultDiffViewerAppearance()
        let targetBundleIdentifier = themeTargetBundleIdentifier(socketPath: socketPath)
        for url in themeConfigSearchURLs(targetBundleIdentifier: targetBundleIdentifier) {
            guard let contents = readOptionalDiffViewerConfig(at: url) else { continue }
            applyDiffViewerGhosttyConfig(contents, to: &appearance)
        }
        if let fontSizeOverride {
            appearance.fontSize = fontSizeOverride
        }
        let themeSuffix = UUID().uuidString.prefix(8)
        appearance.lightTheme.generatedName = "cmux-ghostty-light-\(themeSuffix)"
        appearance.darkTheme.generatedName = "cmux-ghostty-dark-\(themeSuffix)"
        appearance.lightTheme.type = diffViewerThemeType(forBackground: appearance.lightTheme.background, fallback: "light")
        appearance.darkTheme.type = diffViewerThemeType(forBackground: appearance.darkTheme.background, fallback: "dark")
        return appearance
    }

    private func defaultDiffViewerAppearance() -> DiffViewerAppearance {
        var lightTheme = DiffViewerTheme(
            generatedName: "cmux-ghostty-light",
            ghosttyName: "Apple System Colors Light",
            type: "light",
            background: "#feffff",
            foreground: "#000000",
            selectionBackground: "#abd8ff",
            selectionForeground: "#000000",
            palette: [:]
        )
        applyDiffViewerThemeContents(diffViewerDefaultThemeConfigContents(preferredColorScheme: .light), to: &lightTheme)

        var darkTheme = DiffViewerTheme(
            generatedName: "cmux-ghostty-dark",
            ghosttyName: "Apple System Colors",
            type: "dark",
            background: "#1e1e1e",
            foreground: "#ffffff",
            selectionBackground: "#3f638b",
            selectionForeground: "#ffffff",
            palette: [:]
        )
        applyDiffViewerThemeContents(diffViewerDefaultThemeConfigContents(preferredColorScheme: .dark), to: &darkTheme)

        return DiffViewerAppearance(
            backgroundOpacity: 1,
            fontFamily: "Menlo",
            fontSize: 10,
            lightTheme: lightTheme,
            darkTheme: darkTheme
        )
    }

    private func applyDiffViewerGhosttyConfig(_ contents: String, to appearance: inout DiffViewerAppearance) {
        for line in contents.components(separatedBy: .newlines) {
            guard let (key, value) = diffViewerGhosttyAssignment(from: line) else { continue }

            switch key {
            case "font-family":
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    appearance.fontFamily = trimmed
                }
            case "font-size":
                if let fontSize = diffViewerConfigFontSize(value) {
                    appearance.fontSize = fontSize
                }
            case "background-opacity":
                if let backgroundOpacity = diffViewerConfigUnitInterval(value) {
                    appearance.backgroundOpacity = backgroundOpacity
                }
            case "theme":
                applyDiffViewerThemeDirective(value, to: &appearance)
            default:
                applyDiffViewerThemeAssignment(key: key, value: value, to: &appearance.lightTheme)
                applyDiffViewerThemeAssignment(key: key, value: value, to: &appearance.darkTheme)
            }
        }
    }

    private func applyDiffViewerThemeDirective(_ rawValue: String, to appearance: inout DiffViewerAppearance) {
        let lightThemeName = resolveDiffViewerThemeName(from: rawValue, preferredColorScheme: .light)
        if let theme = loadDiffViewerGhosttyTheme(
            named: lightThemeName,
            generatedName: "cmux-ghostty-light",
            fallbackType: "light",
            baseTheme: appearance.lightTheme
        ) {
            appearance.lightTheme = theme
        } else if !lightThemeName.isEmpty {
            appearance.lightTheme.ghosttyName = lightThemeName
        }

        let darkThemeName = resolveDiffViewerThemeName(from: rawValue, preferredColorScheme: .dark)
        if let theme = loadDiffViewerGhosttyTheme(
            named: darkThemeName,
            generatedName: "cmux-ghostty-dark",
            fallbackType: "dark",
            baseTheme: appearance.darkTheme
        ) {
            appearance.darkTheme = theme
        } else if !darkThemeName.isEmpty {
            appearance.darkTheme.ghosttyName = darkThemeName
        }
    }

    private func loadDiffViewerGhosttyTheme(
        named rawThemeName: String,
        generatedName: String,
        fallbackType: String,
        baseTheme: DiffViewerTheme
    ) -> DiffViewerTheme? {
        let themeName = rawThemeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !themeName.isEmpty else { return nil }

        for candidateName in diffViewerThemeNameCandidates(from: themeName) {
            for directoryURL in themeDirectoryURLs() {
                let themeURL = directoryURL.appendingPathComponent(candidateName, isDirectory: false)
                guard let contents = try? String(contentsOf: themeURL, encoding: .utf8) else {
                    continue
                }

                var theme = baseTheme
                theme.generatedName = generatedName
                theme.ghosttyName = candidateName
                applyDiffViewerThemeContents(contents, to: &theme)
                theme.type = diffViewerThemeType(forBackground: theme.background, fallback: fallbackType)
                return theme
            }
        }

        return nil
    }

    private func applyDiffViewerThemeContents(_ contents: String, to theme: inout DiffViewerTheme) {
        for line in contents.components(separatedBy: .newlines) {
            guard let (key, value) = diffViewerGhosttyAssignment(from: line) else { continue }
            applyDiffViewerThemeAssignment(key: key, value: value, to: &theme)
        }
    }

    private func applyDiffViewerThemeAssignment(key: String, value: String, to theme: inout DiffViewerTheme) {
        switch key {
        case "background":
            if let color = normalizedDiffViewerHexColor(value) {
                theme.background = color
            }
        case "foreground":
            if let color = normalizedDiffViewerHexColor(value) {
                theme.foreground = color
            }
        case "selection-background":
            if let color = normalizedDiffViewerHexColor(value) {
                theme.selectionBackground = color
            }
        case "selection-foreground":
            if let color = normalizedDiffViewerHexColor(value) {
                theme.selectionForeground = color
            }
        case "palette":
            let paletteParts = value.split(separator: "=", maxSplits: 1).map(String.init)
            guard paletteParts.count == 2,
                  let index = Int(paletteParts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  (0...15).contains(index),
                  let color = normalizedDiffViewerHexColor(paletteParts[1]) else {
                return
            }
            theme.palette[index] = color
        default:
            break
        }
    }

    private func readOptionalDiffViewerConfig(at url: URL) -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path) {
            if let type = attributes[.type] as? FileAttributeType,
               type != .typeRegular && type != .typeSymbolicLink {
                return nil
            }
            if let size = attributes[.size] as? NSNumber, size.intValue == 0 {
                return nil
            }
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func diffViewerGhosttyAssignment(from line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 2 else { return nil }

        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private func resolveDiffViewerThemeName(
        from rawThemeValue: String,
        preferredColorScheme: DiffViewerColorScheme
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
        return ""
    }

    private func diffViewerThemeNameCandidates(from rawName: String) -> [String] {
        var candidates: [String] = []
        let compatibilityAliasGroups = [
            ["Solarized Light", "iTerm2 Solarized Light"],
            ["Solarized Dark", "iTerm2 Solarized Dark"]
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

    func normalizedDiffViewerHexColor(_ rawValue: String) -> String? {
        var hex = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard !hex.isEmpty, hex.allSatisfy(\.isHexDigit) else { return nil }

        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 else { return nil }
        return "#\(hex.lowercased())"
    }

    private func diffViewerThemeType(forBackground background: String, fallback: String) -> String {
        guard let rgb = diffViewerRGBColor(background) else {
            return fallback
        }
        let luminance = (0.2126 * rgb.red) + (0.7152 * rgb.green) + (0.0722 * rgb.blue)
        return luminance > 0.55 ? "light" : "dark"
    }

    func diffViewerRGBColor(_ rawValue: String) -> (red: Double, green: Double, blue: Double)? {
        guard let color = normalizedDiffViewerHexColor(rawValue) else { return nil }
        let hex = String(color.dropFirst())
        guard let value = UInt32(hex, radix: 16) else { return nil }
        return (
            red: Double((value & 0xFF0000) >> 16) / 255.0,
            green: Double((value & 0x00FF00) >> 8) / 255.0,
            blue: Double(value & 0x0000FF) / 255.0
        )
    }

    func isUsableDiffViewerFontSize(_ size: Double) -> Bool {
        size.isFinite && size > 0 && size <= 96
    }

    private func diffViewerConfigFontSize(_ rawValue: String) -> Double? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Double(trimmed),
              isUsableDiffViewerFontSize(size) else {
            return nil
        }
        return roundedDiffViewerMetric(size)
    }

    private func diffViewerConfigUnitInterval(_ rawValue: String) -> Double? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let rawNumber: String
        let divisor: Double
        if trimmed.hasSuffix("%") {
            rawNumber = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            divisor = 100
        } else {
            rawNumber = trimmed
            divisor = 1
        }
        guard let value = Double(rawNumber), value.isFinite else { return nil }

        return roundedDiffViewerMetric(min(1, max(0, value / divisor)))
    }

    func roundedDiffViewerMetric(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private func diffViewerDefaultThemeConfigContents(preferredColorScheme: DiffViewerColorScheme) -> String {
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
            selection-background = #3f638b
            selection-foreground = #ffffff
            """
        }
    }

}
