import Foundation
import CmuxFoundation
import Darwin

extension CMUXCLI {
    static let cmuxThemeOverrideBundleIdentifier = CmuxGhosttyConfigPathResolver.releaseBundleIdentifier
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

    private enum InteractiveHelperResult: Equatable {
        case completed
        case cancelled
    }

    private func shouldUseInteractiveThemePicker(jsonOutput: Bool) -> Bool {
        guard !jsonOutput else { return false }
        return isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }

    private func runInteractiveThemes(
        socketPath: String,
        targetBundleIdentifier: String,
        explicitPassword: String?
    ) throws {
        guard let helperURL = bundledHelperURL(named: "ghostty") else {
            throw CLIError(message: "Bundled Ghostty theme picker helper not found")
        }

        let selection = currentThemeSelection(targetBundleIdentifier: targetBundleIdentifier)
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_THEME_PICKER_CONFIG"] = try cmuxThemeOverrideConfigURL(
            targetBundleIdentifier: targetBundleIdentifier
        ).path
        environment["CMUX_THEME_PICKER_BUNDLE_ID"] = targetBundleIdentifier
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

        let result = try runInteractiveHelper(
            executablePath: helperURL.path,
            arguments: ["+list-themes"],
            environment: environment
        )
        guard result == .completed else { return }
        _ = reloadThemesIfPossible(
            socketPath: socketPath,
            targetBundleIdentifier: targetBundleIdentifier,
            explicitPassword: explicitPassword
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

            let projectMarker = current.appendingPathComponent("cmux.xcodeproj/project.pbxproj", isDirectory: false)
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

    private func runInteractiveHelper(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> InteractiveHelperResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        let originalForegroundProcessGroup = isatty(STDIN_FILENO) == 1 ? tcgetpgrp(STDIN_FILENO) : -1
        var didForegroundChild = false
        do {
            try cliRunProcess(process)
        } catch {
            throw CLIError(message: "Failed to launch interactive theme picker: \(String(describing: error))")
        }
        if originalForegroundProcessGroup > 0 {
            let childProcessGroup = getpgid(process.processIdentifier)
            if childProcessGroup > 0 && childProcessGroup != originalForegroundProcessGroup {
                do {
                    try setInteractiveThemePickerForegroundProcessGroup(childProcessGroup)
                    _ = Darwin.kill(-childProcessGroup, SIGCONT)
                    didForegroundChild = true
                } catch {
                    process.terminate()
                    throw error
                }
            }
        }
        defer {
            if didForegroundChild {
                try? setInteractiveThemePickerForegroundProcessGroup(originalForegroundProcessGroup)
            }
        }

        process.waitUntilExit()
        if process.terminationReason == .exit, process.terminationStatus == 0 {
            return .completed
        }

        if isInteractiveThemePickerCancellation(process) {
            return .cancelled
        } else if process.terminationReason == .uncaughtSignal {
            throw CLIError(message: "Interactive theme picker exited from signal \(process.terminationStatus)")
        }
        throw CLIError(message: "Interactive theme picker exited with status \(process.terminationStatus)")
    }

    private func isInteractiveThemePickerCancellation(_ process: Process) -> Bool {
        switch process.terminationReason {
        case .uncaughtSignal:
            return process.terminationStatus == SIGINT || process.terminationStatus == SIGTERM
        case .exit:
            return process.terminationStatus == 130 || process.terminationStatus == 143
        @unknown default:
            return false
        }
    }

    private func setInteractiveThemePickerForegroundProcessGroup(_ processGroup: pid_t) throws {
        let previousHandler = signal(SIGTTOU, SIG_IGN)
        defer { _ = signal(SIGTTOU, previousHandler) }
        guard tcsetpgrp(STDIN_FILENO, processGroup) == 0 else {
            throw CLIError(message: "Interactive theme picker failed to enter foreground: \(String(cString: strerror(errno)))")
        }
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

            let projectMarker = current.appendingPathComponent("cmux.xcodeproj/project.pbxproj", isDirectory: false)
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

    func runThemes(
        commandArgs: [String],
        jsonOutput: Bool,
        socketPath: String,
        explicitPassword: String?
    ) throws {
        let targetBundleIdentifier = themeTargetBundleIdentifier(socketPath: socketPath)
        if commandArgs.isEmpty {
            if shouldUseInteractiveThemePicker(jsonOutput: jsonOutput) {
                try runInteractiveThemes(
                    socketPath: socketPath,
                    targetBundleIdentifier: targetBundleIdentifier,
                    explicitPassword: explicitPassword
                )
                return
            }
            try printThemesList(
                jsonOutput: jsonOutput,
                targetBundleIdentifier: targetBundleIdentifier
            )
            return
        }

        guard let subcommand = commandArgs.first else {
            try printThemesList(
                jsonOutput: jsonOutput,
                targetBundleIdentifier: targetBundleIdentifier
            )
            return
        }

        switch subcommand {
        case "list":
            if commandArgs.count > 1 {
                throw CLIError(message: "themes list does not take any positional arguments")
            }
            try printThemesList(
                jsonOutput: jsonOutput,
                targetBundleIdentifier: targetBundleIdentifier
            )
        case "set":
            try runThemesSet(
                args: Array(commandArgs.dropFirst()),
                jsonOutput: jsonOutput,
                socketPath: socketPath,
                targetBundleIdentifier: targetBundleIdentifier,
                explicitPassword: explicitPassword
            )
        case "here":
            try runThemesHere(
                args: Array(commandArgs.dropFirst()),
                jsonOutput: jsonOutput
            )
        case "clear":
            if commandArgs.count > 1 {
                throw CLIError(message: "themes clear does not take any positional arguments")
            }
            try runThemesClear(
                jsonOutput: jsonOutput,
                socketPath: socketPath,
                targetBundleIdentifier: targetBundleIdentifier,
                explicitPassword: explicitPassword
            )
        default:
            if subcommand.hasPrefix("-") {
                throw CLIError(message: "Unknown themes subcommand '\(subcommand)'. Run 'cmux themes --help'.")
            }

            try runThemesSet(
                args: commandArgs,
                jsonOutput: jsonOutput,
                socketPath: socketPath,
                targetBundleIdentifier: targetBundleIdentifier,
                explicitPassword: explicitPassword
            )
        }
    }

    private func printThemesList(
        jsonOutput: Bool,
        targetBundleIdentifier: String
    ) throws {
        let themes = availableThemeNames()
        let current = currentThemeSelection(targetBundleIdentifier: targetBundleIdentifier)
        let configPath = try cmuxThemeOverrideConfigURL(
            targetBundleIdentifier: targetBundleIdentifier
        ).path

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

    private func runThemesSet(
        args: [String],
        jsonOutput: Bool,
        socketPath: String,
        targetBundleIdentifier: String,
        explicitPassword: String?
    ) throws {
        let (lightOpt, rem0) = parseOption(args, name: "--light")
        let (darkOpt, rem1) = parseOption(rem0, name: "--dark")

        if let unknown = rem1.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "themes set: unknown flag '\(unknown)'. Known flags: --light <theme>, --dark <theme>")
        }

        let availableThemes = availableThemeNames()
        let current = currentThemeSelection(targetBundleIdentifier: targetBundleIdentifier)

        let lightTheme: String?
        let darkTheme: String?

        if lightOpt == nil && darkOpt == nil {
            let joinedTheme = rem1.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joinedTheme.isEmpty else {
                throw CLIError(message: "themes set requires a theme name or --light/--dark flags")
            }
            let resolved = try validatedThemeName(joinedTheme, availableThemes: availableThemes)
            lightTheme = resolved
            darkTheme = resolved
        } else {
            if !rem1.isEmpty {
                throw CLIError(message: "themes set: unexpected argument '\(rem1.joined(separator: " "))'")
            }
            lightTheme = try lightOpt.map { try validatedThemeName($0, availableThemes: availableThemes) } ?? current.light
            darkTheme = try darkOpt.map { try validatedThemeName($0, availableThemes: availableThemes) } ?? current.dark
        }

        guard let rawThemeValue = encodedThemeValue(light: lightTheme, dark: darkTheme) else {
            throw CLIError(message: "themes set requires at least one theme")
        }

        let configURL = try writeManagedThemeOverride(
            rawThemeValue: rawThemeValue,
            targetBundleIdentifier: targetBundleIdentifier
        )
        let reloadStatus = reloadThemesIfPossible(
            socketPath: socketPath,
            targetBundleIdentifier: targetBundleIdentifier,
            explicitPassword: explicitPassword
        )

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

    private func runThemesClear(
        jsonOutput: Bool,
        socketPath: String,
        targetBundleIdentifier: String,
        explicitPassword: String?
    ) throws {
        let configURL = try clearManagedThemeOverride(targetBundleIdentifier: targetBundleIdentifier)
        let reloadStatus = reloadThemesIfPossible(
            socketPath: socketPath,
            targetBundleIdentifier: targetBundleIdentifier,
            explicitPassword: explicitPassword
        )

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

    /// Applies a theme to the invoking terminal surface only, by writing OSC dynamic-color
    /// sequences to stdout. Unlike `themes set` this touches no config file and affects no
    /// other surface, window, or future session.
    private func runThemesHere(args: [String], jsonOutput: Bool) throws {
        guard !jsonOutput else {
            throw CLIError(
                message: "themes here writes escape sequences to the terminal and does not support --json"
            )
        }

        var remaining = args
        var shouldReset = false
        if let resetIndex = remaining.firstIndex(of: "--reset") {
            shouldReset = true
            remaining.remove(at: resetIndex)
        }

        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "themes here: unknown flag '\(unknown)'. Known flags: --reset")
        }

        if shouldReset {
            guard remaining.isEmpty else {
                throw CLIError(message: "themes here: --reset does not take a theme name")
            }
            print(Self.paneThemeResetSequence, terminator: "")
            return
        }

        let requestedTheme = remaining.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedTheme.isEmpty else {
            throw CLIError(message: "themes here requires a theme name or a path to a theme file")
        }

        let contents = try paneThemeContents(forRequestedTheme: requestedTheme)
        let sequence = Self.paneThemeSequence(forThemeContents: contents)
        guard !sequence.isEmpty else {
            throw CLIError(message: "Theme '\(requestedTheme)' does not define any terminal colors")
        }
        print(sequence, terminator: "")
    }

    /// Resolves a `themes here` argument as either a path to a theme file or the name of a
    /// theme in one of the known theme directories.
    private func paneThemeContents(forRequestedTheme requestedTheme: String) throws -> String {
        let candidatePath = resolvePath(requestedTheme)
        if FileManager.default.fileExists(atPath: candidatePath),
           let contents = try? String(contentsOfFile: candidatePath, encoding: .utf8) {
            return contents
        }

        let themeName = try validatedThemeName(requestedTheme, availableThemes: availableThemeNames())
        for directoryURL in themeDirectoryURLs() {
            let themeURL = directoryURL.appendingPathComponent(themeName, isDirectory: false)
            if let contents = try? String(contentsOf: themeURL, encoding: .utf8) {
                return contents
            }
        }

        throw CLIError(message: "Unable to read theme '\(requestedTheme)'")
    }

    private func currentThemeSelection(targetBundleIdentifier: String) -> ThemeSelection {
        var rawValue: String?
        var sourcePath: String?

        for url in themeConfigSearchURLs(targetBundleIdentifier: targetBundleIdentifier) {
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

    /// OSC 110/111/112/104: drop surface-local background, foreground, cursor, and palette
    /// overrides so the surface falls back to the colors its config specifies.
    static let paneThemeResetSequence = "\u{1B}]110\u{07}\u{1B}]111\u{07}\u{1B}]112\u{07}\u{1B}]104\u{07}"

    /// Translates a Ghostty theme file into the OSC dynamic-color sequences that apply it to a
    /// single terminal surface. Returns an empty string when the file declares no usable colors.
    static func paneThemeSequence(forThemeContents contents: String) -> String {
        var sequence = ""
        for line in contents.components(separatedBy: .newlines) {
            guard let (key, value) = paneThemeAssignment(from: line) else { continue }
            switch key {
            case "background":
                guard let color = paneThemeHexColor(value) else { continue }
                sequence += "\u{1B}]11;\(color)\u{07}"
            case "foreground":
                guard let color = paneThemeHexColor(value) else { continue }
                sequence += "\u{1B}]10;\(color)\u{07}"
            case "cursor-color":
                guard let color = paneThemeHexColor(value) else { continue }
                sequence += "\u{1B}]12;\(color)\u{07}"
            case "palette":
                let paletteParts = value.split(separator: "=", maxSplits: 1).map(String.init)
                guard paletteParts.count == 2,
                      let index = Int(paletteParts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                      (0...255).contains(index),
                      let color = paneThemeHexColor(paletteParts[1]) else { continue }
                sequence += "\u{1B}]4;\(index);\(color)\u{07}"
            default:
                continue
            }
        }
        return sequence
    }

    private static func paneThemeAssignment(from line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 2 else { return nil }

        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = parts[1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private static func paneThemeHexColor(_ rawValue: String) -> String? {
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
