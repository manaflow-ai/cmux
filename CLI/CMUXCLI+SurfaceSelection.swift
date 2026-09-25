import Foundation

extension CMUXCLI {
    func validateExplicitSurfaceTargetBeforeSocket(
        command: String,
        commandArgs: [String]
    ) throws {
        guard command == "send" || command == "send-key" || command == "read-screen" else {
            return
        }

        // Scan both target flags before parsing either one. A malformed value
        // such as `--surface --workspace <id>` must not be hidden by the later
        // valid workspace option and reach socket dispatch.
        var pastTerminator = false
        for (index, argument) in commandArgs.enumerated() {
            if argument == "--" {
                pastTerminator = true
                continue
            }
            guard !pastTerminator else { continue }

            let targetNames = ["--workspace", "--surface"]
            if targetNames.contains(argument) {
                let value = index + 1 < commandArgs.count ? commandArgs[index + 1] : nil
                if value == nil || value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true || value?.hasPrefix("-") == true {
                    try requireExplicitSurfaceTarget(commandName: command, workspaceArgument: nil, surfaceArgument: nil)
                }
            } else if let targetName = targetNames.first(where: { argument.hasPrefix("\($0)=") }) {
                let value = String(argument.dropFirst(targetName.count + 1))
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.hasPrefix("-") {
                    try requireExplicitSurfaceTarget(commandName: command, workspaceArgument: nil, surfaceArgument: nil)
                }
            }
        }

        let (workspaceArgument, afterWorkspace) = parseOption(commandArgs, name: "--workspace")
        let (surfaceArgument, _) = parseOption(afterWorkspace, name: "--surface")
        try requireExplicitSurfaceTarget(
            commandName: command,
            workspaceArgument: workspaceArgument,
            surfaceArgument: surfaceArgument
        )
    }

    func requireExplicitSurfaceTarget(
        commandName: String,
        workspaceArgument: String?,
        surfaceArgument: String?
    ) throws {
        func isUsableTarget(_ argument: String?) -> Bool {
            guard let trimmed = argument?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  !trimmed.hasPrefix("-") else {
                return false
            }
            return true
        }

        let hasWorkspace = isUsableTarget(workspaceArgument)
        let hasSurface = isUsableTarget(surfaceArgument)
        guard hasWorkspace || hasSurface else {
            let message = String(
                format: String(
                    localized: "cli.error.explicitSurfaceTargetRequired",
                    defaultValue: "%1$@: --workspace or --surface is required; pass an explicit target instead of relying on the focused workspace."
                ),
                commandName
            )
            throw CLIError(message: message, exitCode: 2)
        }
    }

    func runSurfaceSelectionCommand(
        commandName: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        windowOverride: String?,
        includeContextInPlainOutput: Bool,
        requireExplicitTarget: Bool = false
    ) throws {
        let (workspaceOption, remainingAfterWorkspace) = parseOption(
            commandArgs,
            name: "--workspace"
        )
        let (surfaceOption, remainingAfterSurface) = parseOption(
            remainingAfterWorkspace,
            name: "--surface"
        )
        let (windowOption, trailing) = parseOption(
            remainingAfterSurface,
            name: "--window"
        )
        guard trailing.isEmpty else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.readSelection.error.unexpectedArguments",
                    defaultValue: "%@: unexpected arguments: %@"
                ),
                commandName,
                trailing.joined(separator: " ")
            ))
        }

        if requireExplicitTarget {
            try requireExplicitSurfaceTarget(
                commandName: commandName,
                workspaceArgument: workspaceOption,
                surfaceArgument: surfaceOption
            )
        }

        let windowRaw = windowOption ?? windowOverride
        let workspaceRaw = workspaceOption
            ?? Self.callerWorkspaceForSurfaceHandle(surfaceOption, windowRaw: windowRaw)
        let surfaceRaw = surfaceOption
            ?? (workspaceOption == nil && windowRaw == nil
                ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
                : nil)

        var params: [String: Any] = [:]
        let windowID = try normalizeWindowHandle(windowRaw, client: client)
        if let windowID {
            params["window_id"] = windowID
        }
        let workspaceID = try normalizeWorkspaceHandle(
            workspaceRaw,
            client: client,
            windowHandle: windowID
        )
        if let workspaceID {
            params["workspace_id"] = workspaceID
        }
        let surfaceID = try normalizeSurfaceHandle(
            surfaceRaw,
            client: client,
            workspaceHandle: workspaceID,
            windowHandle: windowID
        )
        if let surfaceID {
            params["surface_id"] = surfaceID
        }

        let payload = try client.sendV2(
            method: "surface.read_selection",
            params: params
        )
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        guard (payload["has_selection"] as? Bool) == true else {
            if includeContextInPlainOutput {
                let metadata = surfaceSelectionMetadataLines(payload)
                if !metadata.isEmpty {
                    print(metadata.joined(separator: "\n"))
                    print("")
                }
            }
            print(String(
                localized: "cli.readSelection.output.noActiveSelection",
                defaultValue: "Has selection: false"
            ))
            return
        }

        let text = (payload["text"] as? String) ?? ""
        guard includeContextInPlainOutput else {
            print(text)
            return
        }

        let metadata = surfaceSelectionMetadataLines(payload)
        if !metadata.isEmpty {
            print(metadata.joined(separator: "\n"))
            print("")
        }
        print(text)
    }

    private func surfaceSelectionMetadataLines(
        _ payload: [String: Any]
    ) -> [String] {
        var lines: [String] = []
        if let kind = payload["kind"] as? String, !kind.isEmpty {
            lines.append(String(
                format: String(
                    localized: "cli.readSelection.output.kind",
                    defaultValue: "Kind: %@"
                ),
                kind
            ))
        }
        if let filePath = payload["file_path"] as? String, !filePath.isEmpty {
            lines.append(String(
                format: String(
                    localized: "cli.readSelection.output.file",
                    defaultValue: "File: %@"
                ),
                filePath
            ))
        }
        if let range = payload["line_range"] as? [String: Any],
           let start = surfaceSelectionLineNumber(range["start"]),
           let end = surfaceSelectionLineNumber(range["end"]) {
            if start == end {
                lines.append(String(
                    format: String(
                        localized: "cli.readSelection.output.line",
                        defaultValue: "Line: %lld"
                    ),
                    Int64(start)
                ))
            } else {
                lines.append(String(
                    format: String(
                        localized: "cli.readSelection.output.lines",
                        defaultValue: "Lines: %lld-%lld"
                    ),
                    Int64(start),
                    Int64(end)
                ))
            }
        }
        if let url = payload["url"] as? String, !url.isEmpty {
            lines.append(String(
                format: String(
                    localized: "cli.readSelection.output.url",
                    defaultValue: "URL: %@"
                ),
                url
            ))
        }
        return lines
    }

    private func surfaceSelectionLineNumber(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        return (value as? NSNumber)?.intValue
    }

    static var readSelectionHelp: String {
        String(localized: "cli.help.readSelection", defaultValue: """
        Usage: cmux read-selection [flags]

        Read the active selection from any selectable surface. Plain output includes source context; --json returns the complete response.

        Flags:
          --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
          --surface <id|ref|index>     Target surface (default: $CMUX_SURFACE_ID)
          --window <id|ref|index>      Window context for workspace/surface refs and indexes

        Example:
          cmux read-selection --surface surface:2
          cmux read-selection --surface surface:2 --json
        """)
    }

    static var readScreenHelp: String {
        String(localized: "cli.help.readScreen", defaultValue: "Usage: cmux read-screen (--workspace <id|ref|index> | --surface <id|ref|index>) [flags]\n\nRead terminal text from a surface as plain text.\n\nFlags:\n  --workspace <id|ref|index>   Target workspace (required unless --surface is provided)\n  --surface <id|ref|index>     Target surface (required unless --workspace is provided)\n  --window <id|ref|index>      Window context for workspace/surface refs and indexes\n  --scrollback                 Include scrollback (not just visible viewport)\n  --lines <n>                  Limit to the last n lines (implies --scrollback)\n  --selection                  Read only the active selection; cannot be combined with --scrollback or --lines\n\nExample:\n  cmux read-screen --workspace workspace:2\n  cmux read-screen --surface surface:2 --scrollback --lines 200\n  cmux read-screen --surface surface:2 --selection")
    }

    static var readSelectionUsageLine: String {
        String(
            localized: "cli.usage.readSelection",
            defaultValue: "read-selection [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]"
        )
    }

    static var readScreenUsageLine: String {
        String(
            localized: "cli.usage.readScreen",
            defaultValue: "read-screen (--workspace <id|ref|index> | --surface <id|ref|index>) [--window <id|ref|index>] [--scrollback] [--lines <n>] [--selection]"
        )
    }
}
