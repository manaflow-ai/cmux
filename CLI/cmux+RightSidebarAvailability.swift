import Foundation

extension CMUXCLI {
    private static func appDefaultsCandidates(environment: [String: String] = ProcessInfo.processInfo.environment) -> [UserDefaults] {
        var candidates: [UserDefaults] = []
        if let bundleId = normalizedEnvValue(environment["CMUX_BUNDLE_ID"]),
           let defaults = UserDefaults(suiteName: bundleId) {
            candidates.append(defaults)
        }
        if let bundleId = containingAppBundleIdentifier(),
           let defaults = UserDefaults(suiteName: bundleId) {
            candidates.append(defaults)
        }
        // A CLI launched from PATH or automation has no CMUX_BUNDLE_ID and is
        // not inside the .app bundle; without the release app's suite it would
        // fall through to the CLI's own empty `.standard` domain and report
        // app-enabled beta modes as unavailable (mirrors browserSettingsDomain).
        if let defaults = UserDefaults(suiteName: defaultBrowserSettingsDomain) {
            candidates.append(defaults)
        }
        candidates.append(.standard)
        return candidates
    }

    private static func betaFeatureEnabled(
        key: String,
        defaultValue: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        for defaults in appDefaultsCandidates(environment: environment) {
            if defaults.object(forKey: key) != nil {
                return defaults.bool(forKey: key)
            }
        }
        return defaultValue
    }

    static func availableRightSidebarModeTokens(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var tokens = ["files", "find", "vault", "sessions"]
        if betaFeatureEnabled(key: rightSidebarNotesEnabledDefaultsKey, environment: environment) {
            tokens.append("notes")
        }
        if betaFeatureEnabled(key: rightSidebarFeedEnabledDefaultsKey, environment: environment) {
            tokens.append("feed")
        }
        if betaFeatureEnabled(key: rightSidebarDockEnabledDefaultsKey, environment: environment) {
            tokens.append("dock")
        }
        return tokens
    }

    static func rightSidebarUsage(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let modes = availableRightSidebarModeTokens(environment: environment).joined(separator: "|")
        let template = String(localized: "cli.rightSidebar.usage.template", defaultValue: """
            Usage: cmux right-sidebar <command> [flags]

            Control the right sidebar from the CLI.

            Commands:
              toggle                         Toggle right sidebar visibility
              show                           Show the right sidebar
              hide                           Hide the right sidebar
              focus                          Focus the current right sidebar mode
              set <%@>
                                             Show, switch mode, and focus
              mode                           Print {"visible":bool,"mode":string}
              %@
                                             Alias for show + set + focus

            Flags:
              --workspace <id|ref|index>     Target the window containing a workspace
              --window <id|ref|index>        Target a window
              --no-focus                     With set, switch mode without moving focus

            Examples:
              cmux right-sidebar toggle
              cmux right-sidebar set find
              cmux right-sidebar set vault --no-focus
              cmux right-sidebar mode
        """)
        return String(format: template, modes, modes)
    }

    static func noteGlobalUsage(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        guard betaFeatureEnabled(key: rightSidebarNotesEnabledDefaultsKey, environment: environment) else {
            return ""
        }
        return String(localized: "cli.note.globalUsage", defaultValue: """
          note new [--slug <name>] [--attach <none|workspace|surface|terminal>] [--title <text>] [--direction <dir>] [--focus <true|false>]
          note open <slug> [--attach <none|workspace|surface|terminal>] [--direction <dir>] [--focus <true|false>]
          note list [--json]                                                     (list notes in the project)
          note here [--json]                                                     (print the note resolved for the calling surface)
          note path <slug>                                                       (print absolute path for a note slug)
          note read <slug>                                                       (print note content)
          note write <slug> [--text <text>|--stdin|<text...>] [--create <true|false>]
          note append <slug> [--text <text>|--stdin|<text...>] [--create <true|false>]
          note rm <slug>                                                         (delete a note file)
          """)
    }

    // Presentation flags are global, but command option values can also look like flags.
    static let commandOptionsWithValues: Set<String> = [
        "--action", "--after-workspace", "--agent", "--amount", "--arch",
        "--attr", "--before-workspace", "--body", "--color", "--command",
        "--config", "--create", "--cwd", "--description", "--direction", "--domain",
        "--dx", "--dy", "--email", "--event", "--expires", "--focus",
        "--function", "--id", "--image", "--index", "--key", "--kind",
        "--label", "--layout", "--lines", "--load-state", "--max-depth", "--name", "--os",
        "--order", "--out", "--pane", "--panel", "--path", "--profile", "--property",
        "--provider", "--relay-port", "--script", "--selector", "--session",
        "--shell", "--source", "--subtitle", "--surface", "--tab", "--target-pane", "--team",
        "--text", "--timeout", "--timeout-ms", "--title", "--transcript",
        "--turn", "--type", "--url", "--url-contains", "--value", "--window",
        "--workspace", "--checkpoint", "--checkpoint-id",
    ]
}
