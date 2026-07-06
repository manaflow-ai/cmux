import Foundation

/// `cmux extension …` — Dock TUI extensions from the terminal, herdr-style:
/// list, install (preview → y/N consent → pinned install), update, uninstall,
/// link/unlink for local development, open, and path queries. The app does
/// the actual staging/pinning; the CLI's interactive preview stands in for
/// the GUI consent sheet, confirming a one-shot `preview_token`.
extension CMUXCLI {
    func runExtensionCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput inheritedJSONOutput: Bool
    ) throws {
        var jsonOutput = inheritedJSONOutput
        var assumeYes = false
        var ref: String?
        var positionals: [String] = []

        var index = 0
        while index < commandArgs.count {
            let arg = commandArgs[index]
            switch arg {
            case "--json":
                jsonOutput = true
            case "--yes", "-y":
                assumeYes = true
            case "--ref":
                index += 1
                guard index < commandArgs.count else {
                    throw CLIError(message: String(
                        localized: "cli.extension.error.refValue",
                        defaultValue: "--ref requires a value (branch, tag, or commit SHA)"
                    ))
                }
                ref = commandArgs[index]
            default:
                if arg.hasPrefix("--ref=") {
                    ref = String(arg.dropFirst("--ref=".count))
                } else {
                    positionals.append(arg)
                }
            }
            index += 1
        }

        guard let action = positionals.first?.lowercased() else {
            throw CLIError(message: String(
                localized: "cli.extension.error.missingCommand",
                defaultValue: "extension requires a subcommand: list, install, update, uninstall, link, unlink, open, config-dir, or paths"
            ))
        }
        let remaining = Array(positionals.dropFirst())

        switch action {
        case "list", "ls":
            let payload = try client.sendV2(method: "extension.list")
            if jsonOutput {
                print(jsonString(payload))
            } else {
                printExtensionList(payload)
            }

        case "install", "add":
            guard let source = remaining.first, remaining.count == 1 else {
                throw CLIError(message: String(
                    localized: "cli.extension.error.installArgs",
                    defaultValue: "usage: cmux extension install <owner/repo[/subdir]> [--ref <ref>] [--yes]"
                ))
            }
            var params: [String: Any] = ["source": source]
            if let ref { params["ref"] = ref }
            try runExtensionConsentFlow(
                client: client,
                previewParams: params,
                assumeYes: assumeYes,
                jsonOutput: jsonOutput
            )

        case "update", "upgrade":
            guard let id = remaining.first, remaining.count == 1 else {
                throw CLIError(message: String(
                    localized: "cli.extension.error.updateArgs",
                    defaultValue: "usage: cmux extension update <id> [--yes]"
                ))
            }
            try runExtensionConsentFlow(
                client: client,
                previewParams: ["id": id],
                assumeYes: assumeYes,
                jsonOutput: jsonOutput
            )

        case "uninstall", "remove", "rm":
            guard let id = remaining.first, remaining.count == 1 else {
                throw CLIError(message: String(
                    localized: "cli.extension.error.idArg",
                    defaultValue: "usage: cmux extension \(action) <id>"
                ))
            }
            let payload = try client.sendV2(method: "extension.uninstall", params: ["id": id])
            printExtensionResult(
                payload,
                jsonOutput: jsonOutput,
                fallbackText: String(
                    localized: "cli.extension.uninstalled",
                    defaultValue: "Uninstalled \(id). Its config and state directories were kept."
                )
            )

        case "link":
            guard let rawPath = remaining.first, remaining.count == 1 else {
                throw CLIError(message: String(
                    localized: "cli.extension.error.linkArgs",
                    defaultValue: "usage: cmux extension link <path-to-extension-directory>"
                ))
            }
            let expanded = (rawPath as NSString).expandingTildeInPath
            let absolute = expanded.hasPrefix("/")
                ? expanded
                : FileManager.default.currentDirectoryPath + "/" + expanded
            let path = URL(fileURLWithPath: absolute, isDirectory: true).standardizedFileURL.path
            let payload = try client.sendV2(
                method: "extension.link",
                params: ["path": path],
                responseTimeout: 60
            )
            let id = (payload["id"] as? String) ?? "?"
            printExtensionResult(
                payload,
                jsonOutput: jsonOutput,
                fallbackText: String(
                    localized: "cli.extension.linked",
                    defaultValue: "Linked \(id) from \(path) (development mode: no pin, no build steps)."
                )
            )

        case "unlink":
            guard let id = remaining.first, remaining.count == 1 else {
                throw CLIError(message: String(
                    localized: "cli.extension.error.idArg",
                    defaultValue: "usage: cmux extension \(action) <id>"
                ))
            }
            let payload = try client.sendV2(method: "extension.unlink", params: ["id": id])
            printExtensionResult(
                payload,
                jsonOutput: jsonOutput,
                fallbackText: String(
                    localized: "cli.extension.unlinked",
                    defaultValue: "Unlinked \(id). No files were touched."
                )
            )

        case "open":
            guard let target = remaining.first, remaining.count == 1 else {
                throw CLIError(message: String(
                    localized: "cli.extension.error.openArgs",
                    defaultValue: "usage: cmux extension open <id | id.pane>"
                ))
            }
            // The app resolves dotted targets (extension ids may contain
            // dots, pane ids may not) — the CLI never guesses the split.
            let payload = try client.sendV2(method: "extension.open", params: ["target": target])
            let qualifiedId = (payload["qualified_id"] as? String) ?? target
            printExtensionResult(
                payload,
                jsonOutput: jsonOutput,
                fallbackText: String(
                    localized: "cli.extension.opened",
                    defaultValue: "Opened \(qualifiedId) in the Dock."
                )
            )

        case "config-dir":
            guard let id = remaining.first, remaining.count == 1 else {
                throw CLIError(message: String(
                    localized: "cli.extension.error.idArg",
                    defaultValue: "usage: cmux extension \(action) <id>"
                ))
            }
            let payload = try client.sendV2(method: "extension.paths", params: ["id": id])
            if jsonOutput {
                print(jsonString(payload))
            } else if let configDir = payload["config_dir"] as? String {
                print(configDir)
            }

        case "paths":
            guard let id = remaining.first, remaining.count == 1 else {
                throw CLIError(message: String(
                    localized: "cli.extension.error.idArg",
                    defaultValue: "usage: cmux extension \(action) <id>"
                ))
            }
            let payload = try client.sendV2(method: "extension.paths", params: ["id": id])
            if jsonOutput {
                print(jsonString(payload))
            } else {
                for key in ["root", "config_dir", "state_dir", "logs_dir"] {
                    if let value = payload[key] as? String {
                        print("\(key): \(value)")
                    }
                }
            }

        default:
            throw CLIError(message: String(
                localized: "cli.extension.error.unknownCommand",
                defaultValue: "unknown extension subcommand '\(action)'. Expected list, install, update, uninstall, link, unlink, open, config-dir, or paths."
            ))
        }
    }

    private func printExtensionResult(
        _ payload: [String: Any],
        jsonOutput: Bool,
        fallbackText: String
    ) {
        if jsonOutput {
            print(jsonString(payload))
        } else {
            print(fallbackText)
        }
    }

    /// preview → render → confirm → install (or discard). `--yes` skips the
    /// prompt for pre-vetted sources (herdr parity); a non-TTY stdin without
    /// `--yes` aborts rather than hanging.
    private func runExtensionConsentFlow(
        client: SocketClient,
        previewParams: [String: Any],
        assumeYes: Bool,
        jsonOutput: Bool
    ) throws {
        // --json promises machine-readable stdout; an interactive prompt would
        // pollute it. Refuse up front (before anything is staged app-side).
        guard !jsonOutput || assumeYes else {
            throw CLIError(message: String(
                localized: "cli.extension.error.jsonNeedsYes",
                defaultValue: "--json installs are non-interactive; pass --yes to confirm without the prompt"
            ))
        }
        let preview = try client.sendV2(
            method: "extension.preview",
            params: previewParams,
            responseTimeout: 620
        )
        guard let token = preview["preview_token"] as? String else {
            throw CLIError(message: String(
                localized: "cli.extension.error.noToken",
                defaultValue: "the app returned no preview token; is this cmux up to date?"
            ))
        }

        if !jsonOutput {
            Self.printExtensionInstallPreview(preview)
        }

        if !assumeYes {
            let ttyIn = isatty(fileno(stdin)) != 0
            guard ttyIn else {
                _ = try? client.sendV2(method: "extension.discard", params: ["preview_token": token])
                throw CLIError(message: String(
                    localized: "cli.extension.error.notATTY",
                    defaultValue: "stdin is not a terminal; pass --yes to install without the interactive prompt"
                ))
            }
            print(String(
                localized: "cli.extension.confirmProceed",
                defaultValue: "\nProceed? [y/N] "
            ), terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                _ = try? client.sendV2(method: "extension.discard", params: ["preview_token": token])
                print(String(localized: "cli.extension.aborted", defaultValue: "Aborted."))
                return
            }
        }

        let installed = try client.sendV2(
            method: "extension.install",
            params: ["preview_token": token],
            responseTimeout: 920
        )
        if jsonOutput {
            print(jsonString(installed))
            return
        }
        let name = (installed["name"] as? String) ?? (installed["id"] as? String) ?? "extension"
        let sha = ((installed["pinned_sha"] as? String)?.prefix(7)).map(String.init) ?? "?"
        print(String(
            localized: "cli.extension.installed",
            defaultValue: "Installed \(name) (pinned to \(sha)). Open it with: cmux extension open \((installed["id"] as? String) ?? "<id>")"
        ))
    }

    private func printExtensionList(_ payload: [String: Any]) {
        let extensions = payload["extensions"] as? [[String: Any]] ?? []
        if extensions.isEmpty {
            print(String(
                localized: "cli.extension.listEmpty",
                defaultValue: "No extensions installed. Install one with: cmux extension install <owner/repo>"
            ))
            return
        }
        let tty = isatty(fileno(stdout)) != 0
        for entry in extensions {
            let id = (entry["id"] as? String) ?? "?"
            let name = (entry["name"] as? String) ?? id
            let version = (entry["version"] as? String).map { " \($0)" } ?? ""
            let source = (entry["source"] as? String) ?? ""
            let enabled = (entry["enabled"] as? Bool) ?? true
            let linked = (entry["linked"] as? Bool) ?? false
            let status = (entry["status"] as? String) ?? "ok"
            var detail = linked
                ? String(localized: "cli.extension.list.linked", defaultValue: "linked")
                : ((entry["pinned_sha"] as? String)?.prefix(7)).map(String.init) ?? ""
            if !enabled {
                detail += detail.isEmpty ? "" : ", "
                detail += String(localized: "cli.extension.list.disabled", defaultValue: "disabled")
            }
            if status != "ok" {
                detail += detail.isEmpty ? "" : ", "
                detail += status
            }
            let dim = ExtensionAnsi.dim(tty)
            let bold = ExtensionAnsi.bold(tty)
            let reset = ExtensionAnsi.reset(tty)
            print("\(bold)\(id)\(reset)  \(name)\(version)  \(dim)\(source)\(detail.isEmpty ? "" : "  (\(detail))")\(reset)")
            for pane in entry["panes"] as? [[String: Any]] ?? [] {
                let qualifiedId = (pane["qualified_id"] as? String) ?? "?"
                let title = (pane["title"] as? String) ?? ""
                print("  \(dim)pane\(reset) \(qualifiedId)  \(title)")
            }
        }
    }

    /// Renders the same consent surface as the GUI sheet, in text: identity,
    /// pinned commit, warnings, and every command that will run.
    static func printExtensionInstallPreview(_ preview: [String: Any]) {
        let tty = isatty(fileno(stdout)) != 0
        let bold = ExtensionAnsi.bold(tty)
        let dim = ExtensionAnsi.dim(tty)
        let yellow = ExtensionAnsi.yellow(tty)
        let reset = ExtensionAnsi.reset(tty)

        let name = (preview["name"] as? String) ?? "?"
        let version = (preview["version"] as? String) ?? ""
        let source = (preview["source"] as? String) ?? ""
        let sha = ((preview["resolved_sha"] as? String)?.prefix(7)).map(String.init) ?? "?"
        print("\(bold)\(name) \(version)\(reset)  \(dim)\(source) @ \(sha)\(reset)")
        if let description = preview["description"] as? String {
            print("  \(description)")
        }
        if (preview["kind"] as? String) == "update", let previous = preview["previous_sha"] as? String {
            print(String(
                localized: "cli.extension.preview.updateFrom",
                defaultValue: "  update: \(String(previous.prefix(7))) → \(sha)"
            ))
        }
        print(String(
            localized: "cli.extension.preview.trust",
            defaultValue: "\(yellow)Not reviewed by cmux. It will run as you, with your environment.\(reset) Installing pins it to \(sha) and enables the Dock beta feature."
        ))
        for warning in preview["warnings"] as? [String] ?? [] {
            print("\(yellow)warning:\(reset) \(warning)")
        }
        let buildCommands = preview["build_commands"] as? [String] ?? []
        if !buildCommands.isEmpty {
            print(String(
                localized: "cli.extension.preview.buildHeader",
                defaultValue: "Runs once at install:"
            ))
            for command in buildCommands {
                print("  \(dim)$\(reset) \(command)")
            }
        }
        let panes = preview["panes"] as? [[String: Any]] ?? []
        if !panes.isEmpty {
            print(String(
                localized: "cli.extension.preview.panesHeader",
                defaultValue: "Runs when you open its Dock panes:"
            ))
            for pane in panes {
                let paneId = (pane["id"] as? String) ?? "?"
                let title = (pane["title"] as? String) ?? ""
                print("  \(paneId)  \(title)")
                if let command = pane["command"] as? String {
                    print("    \(dim)$\(reset) \(command)")
                }
                if let cwd = pane["cwd"] as? String {
                    print("    \(dim)cwd: \(cwd)/\(reset)")
                }
                if let env = pane["env"] as? [String: String], !env.isEmpty {
                    for key in env.keys.sorted() {
                        print("    \(dim)env \(key)=\(env[key] ?? "")\(reset)")
                    }
                }
            }
        }
    }
}

/// ANSI helpers for extension CLI output, gated on TTY (mirrors the
/// install-preview helper's private styling).
private enum ExtensionAnsi {
    static func reset(_ tty: Bool) -> String { tty ? "\u{001B}[0m" : "" }
    static func bold(_ tty: Bool) -> String { tty ? "\u{001B}[1m" : "" }
    static func dim(_ tty: Bool) -> String { tty ? "\u{001B}[2m" : "" }
    static func yellow(_ tty: Bool) -> String { tty ? "\u{001B}[33m" : "" }
}
