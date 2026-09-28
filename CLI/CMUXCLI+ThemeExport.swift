import Foundation
import CmuxFoundation
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

        let configColors = themeConfigSearchURLs(targetBundleIdentifier: targetBundleIdentifier)
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { GhosttyThemeColors(parsing: $0) }
        // Mirrors the app: with no `theme`, cmux draws its own light/dark
        // default unless the config sets terminal colors, which then apply
        // over Ghostty's built-in palette (a `nil` theme here).
        let selection = currentThemeSelection(targetBundleIdentifier: targetBundleIdentifier)
        let configSetsColors = configColors.contains { $0 != GhosttyThemeColors() }
        let lightTheme = selection.light
            ?? (configSetsColors ? nil : GhosttyConfig.cmuxDefaultLightThemeName)
        let darkTheme = selection.dark
            ?? (configSetsColors ? nil : GhosttyConfig.cmuxDefaultDarkThemeName)
        func displayName(_ theme: String?) -> String {
            theme ?? "Ghostty"
        }
        func palette(_ theme: String?) throws -> TerminalPalette {
            let base = try theme.map { try themeFileColors(named: $0) } ?? GhosttyThemeColors()
            return TerminalPalette(colors: configColors.reduce(base) { $0.overlaid(by: $1) })
        }

        let exportsPair = appearance == nil
            && target == .opencode
            && displayName(lightTheme).caseInsensitiveCompare(displayName(darkTheme)) != .orderedSame
        let singleTheme: String?
        switch appearance {
        case "light": singleTheme = lightTheme
        case "dark": singleTheme = darkTheme
        default: singleTheme = defaultAppearancePrefersDarkThemes() ? darkTheme : lightTheme
        }
        let themeName = exportsPair
            ? "\(displayName(darkTheme)) \(displayName(lightTheme))"
            : displayName(singleTheme)

        guard let slug = AgentThemeSlug(name: name ?? themeName) else {
            throw CLIError(message: String(
                localized: "cli.themes.export.error.name",
                defaultValue: "themes export: --name needs at least one letter or digit"
            ))
        }

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

        guard let directory = target.themeDirectory(environment: ProcessInfo.processInfo.environment) else {
            throw CLIError(message: String(
                localized: "cli.themes.export.error.noHome",
                defaultValue: "themes export: HOME is not set, so the theme folder can't be found"
            ))
        }
        let fileURL = directory.appendingPathComponent(slug.fileName, isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: fileURL, options: .atomic)

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
