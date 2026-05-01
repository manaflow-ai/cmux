import ArgumentParser
import Foundation
import Darwin

extension CMUXCLI {
    static let cmuxThemeOverrideBundleIdentifier = "com.cmuxterm.app"
    static let cmuxThemesBlockStart = "# cmux themes start"
    static let cmuxThemesBlockEnd = "# cmux themes end"
    static let cmuxThemesReloadNotificationName = "com.cmuxterm.themes.reload-config"

    struct ThemeSelection {
        let rawValue: String?
        let light: String?
        let dark: String?
        let sourcePath: String?
    }

    struct ThemeReloadStatus {
        let requested: Bool
        let targetBundleIdentifier: String
    }

    enum ThemePickerTargetMode: String {
        case both
        case light
        case dark
    }

    enum ThemesCommandRequest {
        case list
        case clear
        case set(ThemesSetArguments)
    }

    struct ThemesArguments: ParsableArguments {
        @Argument(parsing: .allUnrecognized)
        var tokens: [String] = []

        func commandRequest(using cli: CMUXCLI) throws -> ThemesCommandRequest? {
            guard let subcommand = tokens.first else {
                return nil
            }
            _ = cli.parseKnownCommandName(ThemeSubcommandName.self, raw: subcommand.lowercased())

            switch subcommand {
            case "list":
                guard tokens.count == 1 else {
                    throw CLIError(message: "themes list does not take any positional arguments")
                }
                return .list
            case "set":
                return .set(try cli.parseCLIArguments(ThemesSetArguments.self, Array(tokens.dropFirst())))
            case "clear":
                guard tokens.count == 1 else {
                    throw CLIError(message: "themes clear does not take any positional arguments")
                }
                return .clear
            default:
                guard !subcommand.hasPrefix("-") else {
                    throw CLIError(message: "Unknown themes subcommand '\(subcommand)'. Run 'cmux themes --help'.")
                }
                return .set(try cli.parseCLIArguments(ThemesSetArguments.self, tokens))
            }
        }
    }

    struct ThemesSetArguments: ParsableArguments {
        @Option(name: .long, parsing: .unconditionalSingleValue)
        var light: [String] = []

        @Option(name: .long, parsing: .unconditionalSingleValue)
        var dark: [String] = []

        @Argument(parsing: .allUnrecognized)
        var themeParts: [String] = []

        var lightTheme: String? {
            light.last
        }

        var darkTheme: String? {
            dark.last
        }

        var positionalTheme: String {
            themeParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func shouldUseInteractiveThemePicker(jsonOutput: Bool) -> Bool {
        guard !jsonOutput else { return false }
        return isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }

    private func runInteractiveThemes() throws {
        guard let helperURL = bundledHelperURL(named: "ghostty") else {
            throw CLIError(message: "Bundled Ghostty theme picker helper not found")
        }

        let selection = currentThemeSelection()
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_THEME_PICKER_CONFIG"] = try cmuxThemeOverrideConfigURL().path
        environment["CMUX_THEME_PICKER_BUNDLE_ID"] = currentCmuxAppBundleIdentifier() ?? Self.cmuxThemeOverrideBundleIdentifier
        environment["CMUX_THEME_PICKER_TARGET"] = defaultThemePickerTargetMode(current: selection).rawValue
        environment["CMUX_THEME_PICKER_COLOR_SCHEME"] = defaultAppearancePrefersDarkThemes() ? "dark" : "light"
        if let light = selection.light {
            environment["CMUX_THEME_PICKER_INITIAL_LIGHT"] = light
        }
        if let dark = selection.dark {
            environment["CMUX_THEME_PICKER_INITIAL_DARK"] = dark
        }
        if let resourcesURL = bundledGhosttyResourcesURL() {
            environment["GHOSTTY_RESOURCES_DIR"] = resourcesURL.path
        }

        try execInteractiveHelper(
            executablePath: helperURL.path,
            arguments: ["+list-themes"],
            environment: environment
        )
    }

    private func defaultThemePickerTargetMode(current: ThemeSelection) -> ThemePickerTargetMode {
        if let light = current.light,
           let dark = current.dark,
           light.caseInsensitiveCompare(dark) == .orderedSame {
            return .both
        }
        return defaultAppearancePrefersDarkThemes() ? .dark : .light
    }

    private func defaultAppearancePrefersDarkThemes() -> Bool {
        let globalDefaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let interfaceStyle = (globalDefaults?["AppleInterfaceStyle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return interfaceStyle?.caseInsensitiveCompare("Dark") == .orderedSame
    }

    private func bundledHelperURL(named helperName: String) -> URL? {
        let fileManager = FileManager.default
        guard let executableURL = resolvedExecutableURL() else { return nil }

        var candidates: [URL] = [
            executableURL.deletingLastPathComponent().appendingPathComponent(helperName, isDirectory: false)
        ]

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.lastPathComponent == "Contents" {
                candidates.append(
                    current
                        .appendingPathComponent("Resources", isDirectory: true)
                        .appendingPathComponent("bin", isDirectory: true)
                        .appendingPathComponent(helperName, isDirectory: false)
                )
            }

            let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj", isDirectory: false)
            let repoHelper = current
                .appendingPathComponent("ghostty", isDirectory: true)
                .appendingPathComponent("zig-out", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent(helperName, isDirectory: false)
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.isExecutableFile(atPath: repoHelper.path) {
                candidates.append(repoHelper)
                break
            }

            guard let parent = parentSearchURL(for: current) else { break }
            current = parent
        }

        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    private func execInteractiveHelper(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> Never {
        var argv = ([executablePath] + arguments).map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
        }
        argv.append(nil)

        var envp = environment
            .map { key, value in strdup("\(key)=\(value)") }
        defer {
            for item in envp {
                free(item)
            }
        }
        envp.append(nil)

        execve(executablePath, &argv, &envp)
        let code = errno
        throw CLIError(message: "Failed to launch interactive theme picker: \(String(cString: strerror(code)))")
    }

    private func bundledGhosttyResourcesURL() -> URL? {
        let fileManager = FileManager.default
        guard let executableURL = resolvedExecutableURL() else { return nil }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.lastPathComponent == "Contents" {
                let candidate = current
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("ghostty", isDirectory: true)
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }

            let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj", isDirectory: false)
            let repoResources = current
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("ghostty", isDirectory: true)
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.fileExists(atPath: repoResources.path) {
                return repoResources
            }

            guard let parent = parentSearchURL(for: current) else { break }
            current = parent
        }

        return Bundle.main.resourceURL?.appendingPathComponent("ghostty", isDirectory: true)
    }

    func runThemes(commandArgs: [String], jsonOutput: Bool) throws {
        let parsed = try parseCLIArguments(ThemesArguments.self, commandArgs)
        guard let request = try parsed.commandRequest(using: self) else {
            if shouldUseInteractiveThemePicker(jsonOutput: jsonOutput) {
                try runInteractiveThemes()
                return
            }
            try printThemesList(jsonOutput: jsonOutput)
            return
        }

        switch request {
        case .list:
            try printThemesList(jsonOutput: jsonOutput)
        case .set(let args):
            try runThemesSet(
                args: args,
                jsonOutput: jsonOutput
            )
        case .clear:
            try runThemesClear(jsonOutput: jsonOutput)
        }
    }

    private func printThemesList(jsonOutput: Bool) throws {
        let themes = availableThemeNames()
        let current = currentThemeSelection()
        let configPath = try cmuxThemeOverrideConfigURL().path

        if jsonOutput {
            let currentPayload: [String: Any] = [
                "raw_value": current.rawValue ?? NSNull(),
                "light": current.light ?? NSNull(),
                "dark": current.dark ?? NSNull(),
                "source_path": current.sourcePath ?? NSNull()
            ]
            let payload: [String: Any] = [
                "themes": themes.map { theme in
                    [
                        "name": theme,
                        "current_light": current.light?.caseInsensitiveCompare(theme) == .orderedSame,
                        "current_dark": current.dark?.caseInsensitiveCompare(theme) == .orderedSame
                    ]
                },
                "current": currentPayload,
                "config_path": configPath
            ]
            print(jsonString(payload))
            return
        }

        print("Current light: \(current.light ?? "inherit")")
        print("Current dark: \(current.dark ?? "inherit")")
        print("Config: \(configPath)")
        if let sourcePath = current.sourcePath {
            print("Source: \(sourcePath)")
        }
        print("")

        guard !themes.isEmpty else {
            print("No themes found.")
            return
        }

        for theme in themes {
            var badges: [String] = []
            if current.light?.caseInsensitiveCompare(theme) == .orderedSame {
                badges.append("light")
            }
            if current.dark?.caseInsensitiveCompare(theme) == .orderedSame {
                badges.append("dark")
            }
            let badgeText = badges.isEmpty ? "" : "  [\(badges.joined(separator: ", "))]"
            print("\(theme)\(badgeText)")
        }
    }

    private func runThemesSet(args: ThemesSetArguments, jsonOutput: Bool) throws {
        if let unknown = args.themeParts.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "themes set: unknown flag '\(unknown)'. Known flags: --light <theme>, --dark <theme>")
        }

        let availableThemes = availableThemeNames()
        let current = currentThemeSelection()

        let lightTheme: String?
        let darkTheme: String?

        if args.lightTheme == nil && args.darkTheme == nil {
            let positionalTheme = args.positionalTheme
            guard !positionalTheme.isEmpty else {
                throw CLIError(message: "themes set requires a theme name or --light/--dark flags")
            }
            let resolved = try validatedThemeName(positionalTheme, availableThemes: availableThemes)
            lightTheme = resolved
            darkTheme = resolved
        } else {
            if !args.themeParts.isEmpty {
                throw CLIError(message: "themes set: unexpected argument '\(args.themeParts.joined(separator: " "))'")
            }
            lightTheme = try args.lightTheme.map { try validatedThemeName($0, availableThemes: availableThemes) } ?? current.light
            darkTheme = try args.darkTheme.map { try validatedThemeName($0, availableThemes: availableThemes) } ?? current.dark
        }

        guard let rawThemeValue = encodedThemeValue(light: lightTheme, dark: darkTheme) else {
            throw CLIError(message: "themes set requires at least one theme")
        }

        let configURL = try writeManagedThemeOverride(rawThemeValue: rawThemeValue)
        let reloadStatus = reloadThemesIfPossible()

        if jsonOutput {
            let payload: [String: Any] = [
                "ok": true,
                "light": lightTheme ?? NSNull(),
                "dark": darkTheme ?? NSNull(),
                "raw_value": rawThemeValue,
                "config_path": configURL.path,
                "reload_requested": reloadStatus.requested,
                "reload_target_bundle_id": reloadStatus.targetBundleIdentifier
            ]
            print(jsonString(payload))
            return
        }

        print(
            "OK light=\(lightTheme ?? "-") dark=\(darkTheme ?? "-") config=\(configURL.path) reload=requested"
        )
    }

    private func runThemesClear(jsonOutput: Bool) throws {
        let configURL = try clearManagedThemeOverride()
        let reloadStatus = reloadThemesIfPossible()

        if jsonOutput {
            let payload: [String: Any] = [
                "ok": true,
                "cleared": true,
                "config_path": configURL.path,
                "reload_requested": reloadStatus.requested,
                "reload_target_bundle_id": reloadStatus.targetBundleIdentifier
            ]
            print(jsonString(payload))
            return
        }

        print("OK cleared config=\(configURL.path) reload=requested")
    }

    private func currentThemeSelection() -> ThemeSelection {
        var rawValue: String?
        var sourcePath: String?

        for url in themeConfigSearchURLs() {
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                  let nextValue = lastThemeDirective(in: contents) else {
                continue
            }
            rawValue = nextValue
            sourcePath = url.path
        }

        return parseThemeSelection(rawValue: rawValue, sourcePath: sourcePath)
    }

    private func parseThemeSelection(rawValue: String?, sourcePath: String?) -> ThemeSelection {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            return ThemeSelection(rawValue: nil, light: nil, dark: nil, sourcePath: sourcePath)
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
        return ThemeSelection(rawValue: rawValue, light: resolvedLight, dark: resolvedDark, sourcePath: sourcePath)
    }

    private func encodedThemeValue(light: String?, dark: String?) -> String? {
        let normalizedLight = light?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDark = dark?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (normalizedLight?.isEmpty == false ? normalizedLight : nil, normalizedDark?.isEmpty == false ? normalizedDark : nil) {
        case let (lightTheme?, darkTheme?):
            return "light:\(lightTheme),dark:\(darkTheme)"
        case let (lightTheme?, nil):
            return "light:\(lightTheme)"
        case let (nil, darkTheme?):
            return "dark:\(darkTheme)"
        case (nil, nil):
            return nil
        }
    }
}
