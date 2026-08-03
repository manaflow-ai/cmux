import Foundation

extension CMUXCLI {
    static let surfaceOverlayCommandUsageLine = String(
        localized: "cli.surfaceOverlay.usageLine",
        defaultValue: "surface overlay <set|list|remove|clear> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]"
    )

    static let surfaceOverlayCommandHelp = String(
        localized: "cli.surfaceOverlay.help",
        defaultValue: """
        Usage: cmux surface overlay set <id> <text> [--anchor <viewport|scrollback|sticky>] [--position <left|center|right>] [target flags]
               cmux surface overlay list [target flags]
               cmux surface overlay remove <id> [target flags]
               cmux surface overlay clear [target flags]

        Render passive one-row strips over a terminal without taking keyboard or mouse input.
        Viewport stays at the visible top. Scrollback stays at the captured top row.
        Sticky follows the captured row, then pins when that row reaches the viewport top.

        Target flags:
          --workspace <id|ref|index>   Workspace context (default: $CMUX_WORKSPACE_ID)
          --surface <id|ref|index>     Terminal context (default: $CMUX_SURFACE_ID)
          --window <id|ref|index>      Window context for workspace and surface refs/indexes

        Set flags:
          --anchor <viewport|scrollback|sticky>   Vertical anchor (default: viewport)
          --position <left|center|right>   Text alignment (default: center)

        Use '-' as text to read the overlay from standard input.

        Examples:
          cmux surface overlay set latest-message "check the auth error"
          printf 'build\\npassed' | cmux surface overlay set build-status - --position right
          cmux surface overlay set review-note "inspect this output" --anchor scrollback --position left
          cmux surface overlay set latest-message "keep this visible" --anchor sticky --position left
        """
    )

    func runSurfaceOverlayCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        guard let subcommand = commandArgs.first?.lowercased() else {
            throw CLIError(message: String(
                localized: "cli.surfaceOverlay.error.missingSubcommand",
                defaultValue: "surface overlay requires set, list, remove, or clear"
            ))
        }
        let rest = Array(commandArgs.dropFirst())
        let target = try surfaceCommandTarget(rest, client: client, windowOverride: windowOverride)
        var params = target.params

        switch subcommand {
        case "set":
            let (anchor, remainingAfterAnchor) = parseOption(target.remaining, name: "--anchor")
            let (position, remainingAfterPosition) = parseOption(
                remainingAfterAnchor,
                name: "--position"
            )
            let split = overlayArguments(splitAtTerminator: remainingAfterPosition)
            guard let id = split.before.first else {
                throw CLIError(message: String(
                    localized: "cli.surfaceOverlay.error.setRequiresID",
                    defaultValue: "surface overlay set requires an id"
                ))
            }
            if let unknown = split.before.dropFirst().first(where: { $0.hasPrefix("--") }) {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(
                        localized: "cli.surfaceOverlay.error.unknownFlagFormat",
                        defaultValue: "surface overlay: unknown flag '%@'"
                    ),
                    unknown
                ))
            }
            let textTokens = Array(split.before.dropFirst()) + split.after
            guard !textTokens.isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.surfaceOverlay.error.setRequiresText",
                    defaultValue: "surface overlay set requires text or '-' for standard input"
                ))
            }
            let text: String
            if textTokens == ["-"] {
                text = String(
                    data: FileHandle.standardInput.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
            } else {
                text = textTokens.joined(separator: " ")
            }
            params["overlay_id"] = id
            params["text"] = text
            if let anchor { params["anchor"] = anchor }
            if let position { params["position"] = position }
            let payload = try client.sendV2(method: "surface.overlay.set", params: params)
            printSurfaceOverlayPayload(
                payload,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                fallback: (payload["overlay"] as? [String: Any])?["id"] as? String ?? id
            )

        case "list":
            try requireNoSurfaceOverlayArguments(target.remaining, subcommand: subcommand)
            let payload = try client.sendV2(method: "surface.overlay.list", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                for overlay in payload["overlays"] as? [[String: Any]] ?? [] {
                    let id = overlay["id"] as? String ?? ""
                    let anchor = overlay["anchor"] as? String ?? ""
                    let position = overlay["position"] as? String ?? ""
                    let text = (overlay["text"] as? String ?? "")
                        .replacingOccurrences(of: "\n", with: "\\n")
                    print("\(id)\t\(anchor)\t\(position)\t\(text)")
                }
            }

        case "remove":
            let split = overlayArguments(splitAtTerminator: target.remaining)
            let arguments = split.before + split.after
            guard let id = arguments.first else {
                throw CLIError(message: String(
                    localized: "cli.surfaceOverlay.error.removeRequiresID",
                    defaultValue: "surface overlay remove requires an id"
                ))
            }
            guard arguments.count == 1 else {
                throw CLIError(message: String(
                    localized: "cli.surfaceOverlay.error.removeExtraArguments",
                    defaultValue: "surface overlay remove accepts one id"
                ))
            }
            params["overlay_id"] = id
            let payload = try client.sendV2(method: "surface.overlay.remove", params: params)
            printSurfaceOverlayPayload(
                payload,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                fallback: (payload["removed"] as? Bool) == true ? "true" : "false"
            )

        case "clear":
            try requireNoSurfaceOverlayArguments(target.remaining, subcommand: subcommand)
            let payload = try client.sendV2(method: "surface.overlay.clear", params: params)
            let removed = payload["removed"] as? Int ?? 0
            printSurfaceOverlayPayload(
                payload,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                fallback: String(removed)
            )

        default:
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.surfaceOverlay.error.unsupportedSubcommandFormat",
                    defaultValue: "Unsupported surface overlay subcommand: %@"
                ),
                subcommand
            ))
        }
    }

    func publishLatestCodexUserMessageOverlay(
        _ prompt: String,
        workspaceId: String,
        surfaceId: String,
        client: SocketClient
    ) throws {
        let boundedPrompt = terminalOverlayText(
            prompt,
            maximumUTF8Bytes: 16_384
        )
        guard !boundedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        _ = try client.sendV2(
            method: "surface.overlay.set",
            params: [
                "workspace_id": workspaceId,
                "surface_id": surfaceId,
                "overlay_id": "agent.codex.latest-user-message",
                "text": boundedPrompt,
                "anchor": "sticky",
                "position": "left",
            ]
        )
    }

    private func terminalOverlayText(_ text: String, maximumUTF8Bytes: Int) -> String {
        guard text.utf8.count > maximumUTF8Bytes else { return text }
        var result = ""
        result.reserveCapacity(maximumUTF8Bytes)
        var remainingBytes = maximumUTF8Bytes
        for character in text {
            let value = String(character)
            let byteCount = value.utf8.count
            guard byteCount <= remainingBytes else { break }
            result.append(character)
            remainingBytes -= byteCount
        }
        return result
    }

    private func overlayArguments(
        splitAtTerminator args: [String]
    ) -> (before: [String], after: [String]) {
        guard let index = args.firstIndex(of: "--") else {
            return (args, [])
        }
        return (
            Array(args[..<index]),
            Array(args[args.index(after: index)...])
        )
    }

    private func requireNoSurfaceOverlayArguments(
        _ args: [String],
        subcommand: String
    ) throws {
        guard args.isEmpty else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.surfaceOverlay.error.unexpectedArgumentFormat",
                    defaultValue: "surface overlay %@: unexpected argument '%@'"
                ),
                subcommand,
                args[0]
            ))
        }
    }

    private func printSurfaceOverlayPayload(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        fallback: String
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(fallback)
        }
    }
}
