import Foundation

extension CMUXCLI {
    func runSettings(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let parsedArgs = docsSettingsArguments(commandArgs)
        let wantsJSON = jsonOutput || parsedArgs.head.contains("--json")
        let args = parsedArgs.arguments
        let subcommand = args.first?.lowercased() ?? "open"

        if hasHelpRequest(beforeSeparator: parsedArgs.head) {
            print(settingsUsage())
            return
        }

        switch subcommand {
        case "path", "paths":
            guard args.count == 1 else {
                throw CLIError(message: "Usage: cmux settings path")
            }
            printSettingsPaths(jsonOutput: wantsJSON)
            return
        case "docs", "documentation":
            guard args.count == 1 else {
                throw CLIError(message: "Usage: cmux settings docs")
            }
            if wantsJSON, let reference = docsReference(for: "settings") {
                print(jsonString(docsPayload(reference)))
            } else if let reference = docsReference(for: "settings") {
                printDocsReference(reference)
            }
            return
        case "open":
            let targetRaw: String?
            if args.count > 2 {
                throw CLIError(message: "Usage: cmux settings open [target]")
            } else if let rawTarget = args.dropFirst().first {
                guard let target = settingsTargetRawValue(for: rawTarget) else {
                    throw CLIError(message: "Unknown settings target '\(rawTarget)'. Run 'cmux settings --help'.")
                }
                targetRaw = target
            } else {
                targetRaw = nil
            }
            try openSettingsTarget(
                targetRaw,
                socketPath: socketPath,
                explicitPassword: explicitPassword,
                jsonOutput: wantsJSON
            )
            return
        default:
            guard let targetRaw = settingsTargetRawValue(for: subcommand) else {
                throw CLIError(message: "Unknown settings subcommand '\(subcommand)'. Run 'cmux settings --help'.")
            }
            guard args.count == 1 else {
                throw CLIError(message: "Usage: cmux settings [open [target]|path|docs|<target>]")
            }
            try openSettingsTarget(
                targetRaw,
                socketPath: socketPath,
                explicitPassword: explicitPassword,
                jsonOutput: wantsJSON
            )
        }
    }

    func settingsCommandDoesNotNeedSocket(_ commandArgs: [String]) -> Bool {
        let parsedArgs = docsSettingsArguments(commandArgs)
        let subcommand = parsedArgs.arguments.first?.lowercased() ?? "open"
        return hasHelpRequest(beforeSeparator: parsedArgs.head) ||
            ["path", "paths", "docs", "documentation"].contains(subcommand)
    }

    func settingsUsage() -> String {
        return """
        Usage: cmux settings [open [target]|path|docs|<target>]

        Open cmux Settings, print cmux.json paths, or show settings documentation.

        Subcommands:
          open [target]       Open Settings, optionally to a target section.
          path                Print cmux.json paths, docs URL, and schema URL.
          docs                Print the same output as `cmux docs settings`.

        Targets:
          account, app, terminal, sidebar-appearance, custom-sidebars,
          automation, browser, browser-import, global-hotkey,
          keyboard-shortcuts, shortcuts, workspace-colors, cmux-json,
          json, reset

        Config file:
          \(Self.primarySettingsDisplayPath)
          legacy config: \(Self.legacySettingsDisplayPath)
          legacy app support: \(Self.fallbackSettingsDisplayPath)

        Related (not cmux-owned, but cmux reads it for terminal behavior):
          \(Self.ghosttyConfigDisplayPath)

        Before editing cmux.json:
          Back up any existing cmux.json file to a timestamped .bak copy so the user can revert.

        Reload after editing cmux.json or Ghostty config:
          cmux reload-config   (reloads BOTH and refreshes terminals; no app restart needed)
        """
    }

    private func settingsTargetRawValue(for rawValue: String) -> String? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")

        switch normalized {
        case "account":
            return "account"
        case "app", "general":
            return "app"
        case "terminal":
            return "terminal"
        case "sidebar", "sidebar-appearance", "sidebarappearance":
            return "sidebarAppearance"
        case "custom-sidebars", "customsidebars":
            return "customSidebars"
        case "automation":
            return "automation"
        case "computer-use", "computeruse", "cua":
            return "computerUse"
        case "browser":
            return "browser"
        case "browser-import", "browserimport", "import-browser-data":
            return "browserImport"
        case "global-hotkey", "globalhotkey", "hotkey":
            return "globalHotkey"
        case "keyboard-shortcuts", "keyboardshortcuts", "shortcuts", "keys", "keybindings":
            return "keyboardShortcuts"
        case "workspace-colors", "workspacecolors", "colors":
            return "workspaceColors"
        case "cmux-json", "cmuxjson", "settings-json", "settingsjson", "json", "file", "settings-file":
            return "settingsJSON"
        case "reset":
            return "reset"
        default:
            return nil
        }
    }

    private func openSettingsTarget(
        _ targetRaw: String?,
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        var params: [String: Any] = ["activate": true]
        if let targetRaw {
            params["target"] = targetRaw
        }

        let response = try client.sendV2(method: "settings.open", params: params)
        if jsonOutput {
            print(jsonString(response))
        } else {
            let target = (response["target"] as? String) ?? targetRaw ?? "general"
            print("OK target=\(target)")
        }
    }

    func runShortcuts(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let remaining = commandArgs.filter { $0 != "--" }
        if let unknown = remaining.first {
            throw CLIError(message: "shortcuts: unknown flag '\(unknown)'")
        }

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        let response = try client.sendV2(method: "settings.open", params: [
            "target": "keyboardShortcuts",
            "activate": true,
        ])
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK")
        }
    }
}
