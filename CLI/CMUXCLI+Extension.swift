import Darwin
import Foundation

/// `cmux extension …` — TUI extensions from the terminal, herdr-style:
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
        var noOpen = false
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
            case "--no-open":
                noOpen = true
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
                defaultValue: "extension requires a subcommand: list, install, submit, update, uninstall, link, unlink, open, config-dir, or paths"
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

        case "submit":
            guard let source = remaining.first, remaining.count == 1 else {
                throw CLIError(message: String(
                    localized: "cli.extension.error.submitArgs",
                    defaultValue: "usage: cmux extension submit <owner/repo[/subdir]> [--ref <ref>] [--json] [--no-open]"
                ))
            }
            var params: [String: Any] = ["source": source]
            if let ref { params["ref"] = ref }
            try runExtensionSubmitFlow(
                client: client,
                source: source,
                ref: ref,
                previewParams: params,
                jsonOutput: jsonOutput,
                noOpen: noOpen
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
                    defaultValue: "Opened \(qualifiedId) in the current workspace."
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
                defaultValue: "unknown extension subcommand '\(action)'. Expected list, install, submit, update, uninstall, link, unlink, open, config-dir, or paths."
            ))
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
            responseTimeout: 760
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
        let name = (((installed["name"] as? String) ?? (installed["id"] as? String)) ?? "extension").cmuxTerminalSafe()
        let sha = ((installed["pinned_sha"] as? String)?.prefix(7)).map(String.init) ?? "?"
        print(String(
            localized: "cli.extension.installed",
            defaultValue: "Installed \(name) (pinned to \(sha)). Open it with: cmux extension open \((installed["id"] as? String) ?? "<id>")"
        ))
    }

    private func runExtensionSubmitFlow(
        client: SocketClient,
        source: String,
        ref: String?,
        previewParams: [String: Any],
        jsonOutput: Bool,
        noOpen: Bool
    ) throws {
        let preview = try client.sendV2(
            method: "extension.preview",
            params: previewParams,
            responseTimeout: 760
        )
        guard let token = preview["preview_token"] as? String else {
            throw CLIError(message: String(
                localized: "cli.extension.error.noToken",
                defaultValue: "the app returned no preview token; is this cmux up to date?"
            ))
        }
        defer {
            _ = try? client.sendV2(method: "extension.discard", params: ["preview_token": token])
        }

        let resolvedSource = (preview["source"] as? String) ?? source
        let pinnedSha = preview["resolved_sha"] as? String
        let name = preview["name"] as? String
        let version = preview["version"] as? String
        let description = preview["description"] as? String
        let submitCommand = Self.extensionSubmitCommand(source: resolvedSource, ref: ref)
        let issueURL = CmuxExtensionSubmitIssueURL.build(
            source: resolvedSource,
            pinnedSha: pinnedSha,
            name: name,
            version: version,
            description: description,
            ref: ref,
            validationOutput: Self.extensionSubmitValidationOutput(
                source: resolvedSource,
                ref: ref,
                preview: preview
            )
        )

        if jsonOutput {
            var payload: [String: Any] = [
                "repo": resolvedSource,
                "pinnedSha": pinnedSha ?? "",
                "issueUrl": issueURL.absoluteString,
            ]
            if let name { payload["name"] = name }
            if let version { payload["version"] = version }
            if let description { payload["description"] = description }
            if let panes = preview["panes"] as? [[String: Any]] { payload["panes"] = panes }
            print(jsonString(payload))
            return
        }

        print(String(
            localized: "cli.extension.submit.validated",
            defaultValue: "Validated extension submission preview:"
        ))
        let safeSubmitCommand = submitCommand.cmuxTerminalSafe()
        print(String(
            localized: "cli.extension.submit.command",
            defaultValue: "Command: \(safeSubmitCommand)"
        ))
        Self.printExtensionInstallPreview(preview)
        let safeIssueURL = issueURL.absoluteString.cmuxTerminalSafe()
        print(String(
            localized: "cli.extension.submit.issueURL",
            defaultValue: "Submission issue: \(safeIssueURL)"
        ))

        if !noOpen {
            try openExtensionSubmissionIssue(issueURL)
        }
    }

    private func openExtensionSubmissionIssue(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError(message: String(
                localized: "cli.extension.submit.openFailed",
                defaultValue: "Failed to open the extension submission issue URL."
            ))
        }
    }

    private static func extensionSubmitValidationOutput(
        source: String,
        ref: String?,
        preview: [String: Any]
    ) -> String {
        var lines = [
            extensionSubmitCommand(source: source, ref: ref),
            "Repository: \(source)",
            "Pinned SHA: \((preview["resolved_sha"] as? String) ?? "")",
            "Name: \((preview["name"] as? String) ?? "")",
            "Version: \((preview["version"] as? String) ?? "")",
        ]
        let panes = preview["panes"] as? [[String: Any]] ?? []
        if !panes.isEmpty {
            lines.append("Panes:")
            for pane in panes {
                let id = (pane["id"] as? String) ?? "?"
                let title = (pane["title"] as? String) ?? ""
                lines.append("- \(id): \(title)")
                if let command = pane["command"] as? String {
                    lines.append("  command: \(command)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func extensionSubmitCommand(source: String, ref: String?) -> String {
        "cmux extension submit \(source)\(ref.map { " --ref \($0)" } ?? "")"
    }
}
