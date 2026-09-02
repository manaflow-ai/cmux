import Foundation

extension CMUXCLI {
    func runSurfaceSelectionCommand(
        commandName: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        windowOverride: String?,
        includeContextInPlainOutput: Bool
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
        String(localized: "cli.help.readScreen", defaultValue: """
        Usage: cmux read-screen [flags]

        Read terminal text from a surface as plain text.

        Flags:
          --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
          --surface <id|ref|index>     Target surface (default: $CMUX_SURFACE_ID)
          --window <id|ref|index>      Window context for workspace/surface refs and indexes
          --scrollback                 Include scrollback (not just visible viewport)
          --lines <n>                  Limit to the last n lines (implies --scrollback)
          --selection                  Read only the active selection; cannot be combined with --scrollback or --lines

        Example:
          cmux read-screen
          cmux read-screen --surface surface:2 --scrollback --lines 200
          cmux read-screen --surface surface:2 --selection
        """)
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
            defaultValue: "read-screen [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--scrollback] [--lines <n>] [--selection]"
        )
    }
}
