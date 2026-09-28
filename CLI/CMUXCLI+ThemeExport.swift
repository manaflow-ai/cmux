import Foundation
import CmuxFoundation
import CmuxSettings
import CmuxTerminalCore

extension CMUXCLI {
    static var themesExportUsage: String {
        String(
            localized: "cli.themes.export.usage",
            defaultValue: """
            Usage: cmux themes export --to <claude|opencode> [--write] [--name <name>] [--appearance <light|dark>]

            Renders the terminal colors cmux uses (the Ghostty theme plus any colors
            set in your config) as a theme file for an agent, so Claude Code or
            OpenCode matches your terminal.

            Prints the theme JSON by default. With --write, saves it to the agent's
            theme folder as cmux-<name>.json and prints how to select it. Only files
            named cmux-* are ever written.

            Options:
              --to <agent>            claude (~/.claude/themes) or opencode (~/.config/opencode/themes)
              --write                 Save the file instead of printing it
              --name <name>           File and display name (default: the theme name)
              --appearance <mode>     Export the light or dark theme only. Claude Code
                                      themes have one appearance and default to the
                                      current macOS one; OpenCode gets both.

            Examples:
              cmux themes export --to claude
              cmux themes export --to claude --write
              cmux themes export --to opencode --write --name mocha
            """
        )
    }

    func runThemesExport(
        args: [String],
        jsonOutput: Bool,
        targetBundleIdentifier: String
    ) throws {
        if args.contains("--help") || args.contains("-h") {
            print(Self.themesExportUsage)
            return
        }

        var target: AgentThemeTarget?
        var write = false
        var name: String?
        var appearance: String?
        var index = 0
        while index < args.count {
            let arg = args[index]
            func value() throws -> String {
                guard index + 1 < args.count else {
                    throw CLIError(message: Self.themesExportUnknownFlagMessage(arg))
                }
                index += 1
                return args[index]
            }
            switch arg {
            case "--to":
                let raw = try value()
                guard let parsed = AgentThemeTarget(argument: raw) else {
                    throw CLIError(message: Self.themesExportTargetMessage)
                }
                target = parsed
            case "--write":
                write = true
            case "--name":
                name = try value()
            case "--appearance":
                appearance = try value().lowercased()
                guard appearance == "light" || appearance == "dark" else {
                    throw CLIError(message: String(
                        localized: "cli.themes.export.error.appearance",
                        defaultValue: "themes export: --appearance must be light or dark"
                    ))
                }
            default:
                throw CLIError(message: Self.themesExportUnknownFlagMessage(arg))
            }
            index += 1
        }
        guard let target else {
            throw CLIError(message: Self.themesExportTargetMessage)
        }

        // Read the config the way the app does: every config file in Ghostty's
        // load order, including `config-file` includes, last value wins.
        let configPaths = themeConfigSearchURLs(targetBundleIdentifier: targetBundleIdentifier).map(\.path)
        let summary = GhosttyConfig.userAppearanceConfigSummary(configPaths: configPaths)
        let colorDirectives = GhosttyConfig.resolvedDirectiveValues(
            forKeys: Set(Self.themeExportColorKeys),
            configPaths: configPaths
        ).values
        let configColors = GhosttyThemeColors(parsing: Self.themeExportColorKeys.flatMap { key in
            (colorDirectives[key] ?? []).map { "\(key) = \($0)" }
        }.joined(separator: "\n"))
        // Mirrors the app: with no `theme` and no terminal colors, cmux draws
        // its own light/dark default when the adaptive default theme setting
        // is on. Otherwise the config colors apply over Ghostty's built-in
        // palette (a `nil` theme here).
        let selection = parseThemeSelection(rawValue: summary.lastThemeDirective, sourcePath: nil)
        let usesManagedDefault = summary.shouldApplyDefaultAppearance
            && adaptiveDefaultThemeEnabled(targetBundleIdentifier: targetBundleIdentifier)
        let lightTheme = selection.light
            ?? (usesManagedDefault ? GhosttyConfig.cmuxDefaultLightThemeName : nil)
        let darkTheme = selection.dark
            ?? (usesManagedDefault ? GhosttyConfig.cmuxDefaultDarkThemeName : nil)
        func displayName(_ theme: String?) -> String {
            theme ?? "Ghostty"
        }
        func palette(_ theme: String?) throws -> TerminalPalette {
            let base = try theme.map { try themeFileColors(named: $0) } ?? GhosttyThemeColors()
            return TerminalPalette(colors: base.overlaid(by: configColors))
        }

        let exportsPair = appearance == nil
            && target == .opencode
            && displayName(lightTheme).caseInsensitiveCompare(displayName(darkTheme)) != .orderedSame
        let singleTheme: String?
        switch appearance {
        case "light": singleTheme = lightTheme
        case "dark": singleTheme = darkTheme
        default: singleTheme = appPrefersDarkTheme(targetBundleIdentifier: targetBundleIdentifier) ? darkTheme : lightTheme
        }
        let themeName = exportsPair
            ? "\(displayName(darkTheme)) \(displayName(lightTheme))"
            : displayName(singleTheme)

        let contents: String
        switch target {
        case .claude:
            contents = ClaudeCodeThemeRenderer().render(
                name: name ?? "\(themeName) (cmux)",
                palette: try palette(singleTheme)
            )
        case .opencode:
            let appearances: AgentThemeAppearances = exportsPair
                ? .pair(light: try palette(lightTheme), dark: try palette(darkTheme))
                : .single(try palette(singleTheme))
            contents = OpenCodeThemeRenderer().render(appearances: appearances)
        }

        guard write else {
            print(contents, terminator: "")
            return
        }

        // Only the file name needs a slug, so printing works for any theme name.
        guard let slug = AgentThemeSlug(name: name ?? themeName) else {
            throw CLIError(message: String(
                localized: "cli.themes.export.error.name",
                defaultValue: "themes export: --name needs at least one letter or digit"
            ))
        }

        guard let directory = target.themeDirectory(environment: ProcessInfo.processInfo.environment) else {
            throw CLIError(message: String(
                localized: "cli.themes.export.error.noHome",
                defaultValue: "themes export: HOME is not set, so the theme folder can't be found"
            ))
        }
        let fileURL = directory.appendingPathComponent(slug.fileName, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: fileURL, options: .atomic)
        } catch {
            throw CLIError(message: error.localizedDescription)
        }

        let hint: String
        switch target {
        case .claude:
            hint = String(
                localized: "cli.themes.export.hint.claude",
                defaultValue: "Select it in Claude Code with /theme."
            )
        case .opencode:
            hint = String(
                format: String(
                    localized: "cli.themes.export.hint.opencode",
                    defaultValue: "Select it in OpenCode with /theme, or set \"theme\": \"%@\" in tui.json."
                ),
                slug.value
            )
        }

        if jsonOutput {
            print(jsonString([
                "ok": true,
                "to": target.rawValue,
                "path": fileURL.path,
                "theme": slug.value,
            ]))
            return
        }
        print(fileURL.path)
        print(hint)
    }

    /// Colors from the Ghostty theme file `name` resolves to: a theme name in
    /// the theme directories, or an absolute path as Ghostty accepts.
    private func themeFileColors(named name: String) throws -> GhosttyThemeColors {
        let url: URL?
        if name.hasPrefix("/") {
            url = URL(fileURLWithPath: name, isDirectory: false)
        } else {
            url = GhosttyThemeCatalog(directories: themeDirectoryURLs()).entries()
                .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?
                .url
        }
        guard let url, let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.themes.export.error.themeNotFound",
                    defaultValue: "Theme '%@' not found. Run 'cmux themes list' to see available themes."
                ),
                name
            ))
        }
        return GhosttyThemeColors(parsing: contents)
    }

    /// Config keys that color the terminal and are parsed into ``GhosttyThemeColors``.
    private static let themeExportColorKeys = [
        "background", "foreground", "cursor-color",
        "selection-background", "selection-foreground", "palette",
    ]

    /// The app's adaptive default theme setting (on unless turned off).
    private func adaptiveDefaultThemeEnabled(targetBundleIdentifier: String) -> Bool {
        let key = SettingCatalog().terminal.adaptiveDefaultTheme
        return UserDefaults(suiteName: targetBundleIdentifier)?
            .object(forKey: key.userDefaultsKey) as? Bool ?? key.defaultValue
    }

    /// Whether the terminal currently draws its dark theme: the app's
    /// Light or Dark appearance setting when forced, else macOS's.
    private func appPrefersDarkTheme(targetBundleIdentifier: String) -> Bool {
        let key = SettingCatalog().app.appearance
        let raw = UserDefaults(suiteName: targetBundleIdentifier)?.string(forKey: key.userDefaultsKey)
        switch raw {
        case "light": return false
        case "dark": return true
        default: return defaultAppearancePrefersDarkThemes()
        }
    }

    private static var themesExportTargetMessage: String {
        String(
            localized: "cli.themes.export.error.target",
            defaultValue: "themes export: --to must be claude or opencode"
        )
    }

    private static func themesExportUnknownFlagMessage(_ flag: String) -> String {
        String(
            format: String(
                localized: "cli.themes.export.error.unknownArgument",
                defaultValue: "themes export: unexpected argument '%@'. Run 'cmux themes export --help'."
            ),
            flag
        )
    }
}
