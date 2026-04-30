import Foundation

extension CMUXCLI {
    private static let settingsDocsURL = "https://cmux.com/docs/configuration#settings-json"
    private static let settingsSchemaURL = "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux-settings.schema.json"
    private static let primarySettingsDisplayPath = "~/.config/cmux/settings.json"
    private static let fallbackSettingsDisplayPath = "~/Library/Application Support/com.cmuxterm.app/settings.json"

    private struct DocsResource {
        let label: String
        let url: String
    }

    private struct DocsReference {
        let topic: String
        let aliases: [String]
        let summary: String
        let webURL: String
        let rawResources: [DocsResource]
        let commands: [String]
    }

    private static let docsReferences: [DocsReference] = [
        DocsReference(
            topic: "settings",
            aliases: ["configuration", "config", "settings-json", "schema"],
            summary: "cmux-owned settings, settings.json locations, schema, and reload flow.",
            webURL: settingsDocsURL,
            rawResources: [
                DocsResource(label: "settings schema", url: settingsSchemaURL),
                DocsResource(label: "cmux skill", url: "https://raw.githubusercontent.com/manaflow-ai/cmux/main/skills/cmux/SKILL.md"),
            ],
            commands: [
                "cmux settings path",
                "cmux settings json",
                "cmux reload-config",
            ]
        ),
        DocsReference(
            topic: "shortcuts",
            aliases: ["keyboard", "keybindings", "keys"],
            summary: "cmux-owned keyboard shortcuts and two-step chord syntax.",
            webURL: "https://cmux.com/docs/keyboard-shortcuts",
            rawResources: [
                DocsResource(label: "shortcut data", url: "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux-shortcuts.ts"),
                DocsResource(label: "settings schema", url: settingsSchemaURL),
            ],
            commands: [
                "cmux shortcuts",
                "cmux settings shortcuts",
                "cmux docs settings",
            ]
        ),
        DocsReference(
            topic: "api",
            aliases: ["cli", "socket", "automation", "handles"],
            summary: "CLI/socket API, handle model, windows, workspaces, panes, and surfaces.",
            webURL: "https://cmux.com/docs/api",
            rawResources: [
                DocsResource(label: "CLI contract", url: "https://raw.githubusercontent.com/manaflow-ai/cmux/main/docs/cli-contract.md"),
                DocsResource(label: "cmux skill", url: "https://raw.githubusercontent.com/manaflow-ai/cmux/main/skills/cmux/SKILL.md"),
            ],
            commands: [
                "cmux identify --json",
                "cmux tree --all",
            ]
        ),
        DocsReference(
            topic: "browser",
            aliases: ["browser-automation", "webview"],
            summary: "Browser panel automation commands and snapshot-driven web interaction.",
            webURL: "https://cmux.com/docs/browser-automation",
            rawResources: [
                DocsResource(label: "browser skill", url: "https://raw.githubusercontent.com/manaflow-ai/cmux/main/skills/cmux-browser/SKILL.md"),
                DocsResource(label: "browser commands", url: "https://raw.githubusercontent.com/manaflow-ai/cmux/main/skills/cmux-browser/references/commands.md"),
            ],
            commands: [
                "cmux browser --help",
                "cmux browser snapshot",
            ]
        ),
        DocsReference(
            topic: "agents",
            aliases: ["integrations", "agent-integrations"],
            summary: "Codex, Claude Code, OpenCode, and agent workflow integrations.",
            webURL: "https://cmux.com/docs/agent-integrations/oh-my-codex",
            rawResources: [
                DocsResource(label: "feed docs", url: "https://raw.githubusercontent.com/manaflow-ai/cmux/main/docs/feed.md"),
                DocsResource(label: "notifications docs", url: "https://raw.githubusercontent.com/manaflow-ai/cmux/main/docs/notifications.md"),
            ],
            commands: [
                "cmux codex install-hooks",
                "cmux opencode install-hooks",
                "cmux setup-hooks",
            ]
        ),
    ]

    func runDocsCommand(commandArgs: [String], jsonOutput: Bool) throws {
        let parsedArgs = docsSettingsArguments(commandArgs)
        let wantsJSON = jsonOutput || parsedArgs.head.contains("--json")
        let args = parsedArgs.arguments

        if hasHelpRequest(beforeSeparator: parsedArgs.head) {
            print(docsUsage())
            return
        }

        guard let topic = args.first?.lowercased() else {
            if wantsJSON {
                print(jsonString(["topics": Self.docsReferences.map { docsPayload($0) }]))
            } else {
                printDocsIndex()
            }
            return
        }

        guard args.count == 1 else {
            throw CLIError(message: "Usage: cmux docs [settings|shortcuts|api|browser|agents]")
        }

        if topic == "list" || topic == "all" {
            if wantsJSON {
                print(jsonString(["topics": Self.docsReferences.map { docsPayload($0) }]))
            } else {
                printDocsIndex()
            }
            return
        }

        guard let reference = docsReference(for: topic) else {
            throw CLIError(message: "Unknown docs topic '\(topic)'. Run 'cmux docs' for topics.")
        }

        if wantsJSON {
            print(jsonString(docsPayload(reference)))
        } else {
            printDocsReference(reference)
        }
    }

    func docsUsage() -> String {
        return """
        Usage: cmux docs [settings|shortcuts|api|browser|agents]

        Print the canonical docs URL, raw GitHub resources, and useful commands for a cmux topic.
        This command does not require a running cmux app or socket.

        Agents:
          Use `cmux docs settings` before editing ~/.config/cmux/settings.json.
          Back up any existing settings file to a timestamped .bak copy before editing so the user can revert.
          Fetch raw resources with the printed curl commands when you need the latest schema.
        """
    }

    private func docsReference(for topic: String) -> DocsReference? {
        let normalized = topic.replacingOccurrences(of: "_", with: "-")
        return Self.docsReferences.first { reference in
            reference.topic == normalized || reference.aliases.contains(normalized)
        }
    }

    private func docsPayload(_ reference: DocsReference) -> [String: Any] {
        var payload: [String: Any] = [
            "topic": reference.topic,
            "aliases": reference.aliases,
            "summary": reference.summary,
            "web_url": reference.webURL,
            "raw_resources": reference.rawResources.map { resource in
                [
                    "label": resource.label,
                    "url": resource.url,
                    "fetch": "curl -fsSL \(resource.url)",
                ]
            },
            "commands": reference.commands,
        ]
        if reference.topic == "settings" {
            payload["settings_files"] = [
                "primary": Self.primarySettingsDisplayPath,
                "fallback": Self.fallbackSettingsDisplayPath,
            ]
            payload["backup"] = "Back up any existing settings file to a timestamped .bak copy before editing so the user can revert."
            payload["reload_command"] = "cmux reload-config"
        }
        return payload
    }

    private func printDocsIndex() {
        print("cmux docs")
        print()
        print("Topics:")
        for reference in Self.docsReferences {
            print("  \(reference.topic.padding(toLength: 10, withPad: " ", startingAt: 0)) \(reference.summary)")
        }
        print()
        print("Run `cmux docs <topic>` for URLs, raw resources, and next commands.")
    }

    private func printDocsReference(_ reference: DocsReference) {
        print("\(reference.topic): \(reference.summary)")
        print()
        print("Web:")
        print("  \(reference.webURL)")
        if !reference.rawResources.isEmpty {
            print()
            print("Raw resources:")
            for resource in reference.rawResources {
                print("  \(resource.label): \(resource.url)")
            }
            print()
            print("Fetch:")
            for resource in reference.rawResources {
                print("  curl -fsSL \(resource.url)")
            }
        }
        if !reference.commands.isEmpty {
            print()
            print("Useful commands:")
            for command in reference.commands {
                print("  \(command)")
            }
        }
        if reference.topic == "settings" {
            print()
            print("Settings files:")
            print("  \(Self.primarySettingsDisplayPath)")
            print("  \(Self.fallbackSettingsDisplayPath)")
            print()
            print("Before editing settings.json:")
            print("  Back up any existing settings file to a timestamped .bak copy so the user can revert.")
            print()
            print("After editing settings.json:")
            print("  cmux reload-config")
        }
    }

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
                throw CLIError(message: "Usage: cmux settings [open|path|docs|target]")
            }
            try openSettingsTarget(
                targetRaw,
                socketPath: socketPath,
                explicitPassword: explicitPassword,
                jsonOutput: wantsJSON
            )
        }
    }

    func settingsUsage() -> String {
        return """
        Usage: cmux settings [open|path|docs|target]

        Open cmux Settings, print settings file paths, or show settings documentation.

        Subcommands:
          open [target]       Open Settings, optionally to a target section.
          path                Print settings.json paths, docs URL, and schema URL.
          docs                Print the same output as `cmux docs settings`.

        Targets:
          account, app, terminal, sidebar-appearance, automation, browser,
          browser-import, global-hotkey, keyboard-shortcuts, shortcuts,
          workspace-colors, settings-json, json, reset

        Settings file:
          \(Self.primarySettingsDisplayPath)
          \(Self.fallbackSettingsDisplayPath)

        Before editing settings.json:
          Back up any existing settings file to a timestamped .bak copy so the user can revert.

        After editing settings.json:
          cmux reload-config

        Full docs:
          cmux docs settings
        """
    }

    private func printSettingsPaths(jsonOutput: Bool) {
        let payload: [String: Any] = [
            "primary": Self.primarySettingsDisplayPath,
            "fallback": Self.fallbackSettingsDisplayPath,
            "docs_url": Self.settingsDocsURL,
            "schema_url": Self.settingsSchemaURL,
            "reload_command": "cmux reload-config",
            "backup": "Back up any existing settings file to a timestamped .bak copy before editing so the user can revert.",
        ]

        if jsonOutput {
            print(jsonString(payload))
            return
        }

        print("Settings files:")
        print("  primary:  \(Self.primarySettingsDisplayPath)")
        print("  fallback: \(Self.fallbackSettingsDisplayPath)")
        print()
        print("Docs:")
        print("  \(Self.settingsDocsURL)")
        print()
        print("Schema:")
        print("  \(Self.settingsSchemaURL)")
        print()
        print("Before editing settings.json:")
        print("  Back up any existing settings file to a timestamped .bak copy so the user can revert.")
        print()
        print("After editing settings.json:")
        print("  cmux reload-config")
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
        case "automation":
            return "automation"
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
        case "settings-json", "settingsjson", "json", "file", "settings-file":
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

    private func docsSettingsArguments(_ commandArgs: [String]) -> (head: [String], arguments: [String]) {
        let separatorIndex = commandArgs.firstIndex(of: "--")
        let head = separatorIndex.map { Array(commandArgs[..<$0]) } ?? commandArgs
        let tail = separatorIndex.map { Array(commandArgs[commandArgs.index(after: $0)...]) } ?? []
        let headArguments = head.filter { $0 != "--json" }
        return (head, headArguments + tail)
    }

    private func hasHelpRequest(beforeSeparator args: [String]) -> Bool {
        let positionalArgs = args.filter { $0 != "--json" }
        return args.contains("--help") || args.contains("-h") || positionalArgs.first?.lowercased() == "help"
    }
}
