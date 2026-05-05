import Foundation

extension TerminalThemeSettings {
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
}
