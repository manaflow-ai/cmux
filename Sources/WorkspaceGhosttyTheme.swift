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

    var isComplete: Bool {
        (light != nil && dark != nil) || isEmpty
    }

    var rawValue: String? {
        let trimmedLight = Self.normalizedThemeName(light)
        let trimmedDark = Self.normalizedThemeName(dark)

        switch (trimmedLight, trimmedDark) {
        case let (light?, dark?) where light.caseInsensitiveCompare(dark) == .orderedSame:
            return light
        case let (light?, dark?):
            return "light:\(light),dark:\(dark)"
        case (_?, nil):
            return nil
        case (nil, _?):
            return nil
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
        guard trimmed.rangeOfCharacter(from: .newlines) == nil,
              trimmed.range(of: "\0") == nil else {
            return nil
        }
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
        return selection.isEmpty || !selection.isComplete ? nil : selection
    }

    func configContents() -> String? {
        guard isComplete else { return nil }
        guard let rawValue else { return nil }
        return "theme = \(rawValue)"
    }

    func configContents(preferredColorScheme: GhosttyConfig.ColorSchemePreference) -> String? {
        guard isComplete else { return nil }
        guard let rawValue else { return nil }
        let resolvedTheme = GhosttyConfig.resolveThemeName(
            from: rawValue,
            preferredColorScheme: preferredColorScheme
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedTheme.isEmpty,
              resolvedTheme.rangeOfCharacter(from: .newlines) == nil else {
            return nil
        }
        return "theme = \(resolvedTheme)"
    }

    func resolvedGhosttyConfig(
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) -> GhosttyConfig {
        var config = GhosttyConfig.load(preferredColorScheme: preferredColorScheme, useCache: false)
        if let contents = configContents(preferredColorScheme: preferredColorScheme) {
            config.parse(contents, loadingThemesImmediatelyFor: preferredColorScheme)
        }
        return config
    }
}
