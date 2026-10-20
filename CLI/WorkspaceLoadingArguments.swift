import Foundation

struct WorkspaceLoadingArguments {
    let turnOn: Bool
    let id: String?
    let workspace: String?
    let window: String?
}

extension CMUXCLI {
    func validateWorkspaceLoadingCommandBeforeSocket(
        command: String,
        commandArgs: [String]
    ) throws {
        guard command == "workspace",
              commandArgs.first?.lowercased() == "loading" else {
            return
        }
        _ = try parseWorkspaceLoadingArguments(Array(commandArgs.dropFirst()))
    }

    func workspaceLoadingUsage() -> String {
        String(
            localized: "cli.workspaceLoading.usage",
            defaultValue: "Usage: cmux workspace loading <on|off> [--id <name>] [--workspace <id>] [--window <id>] [--json]"
        )
    }

    func parseWorkspaceLoadingArguments(_ commandArgs: [String]) throws -> WorkspaceLoadingArguments {
        let usage = workspaceLoadingUsage()
        var idArg: String?
        var wsArg: String?
        var winArg: String?
        var positional: [String] = []
        var index = 0
        var pastTerminator = false

        func requireValue() throws -> String {
            let valueIndex = index + 1
            guard valueIndex < commandArgs.count, !commandArgs[valueIndex].hasPrefix("--") else {
                throw CLIError(message: usage)
            }
            return commandArgs[valueIndex]
        }

        while index < commandArgs.count {
            let arg = commandArgs[index]
            if !pastTerminator, arg == "--" {
                pastTerminator = true
                index += 1
                continue
            }
            if !pastTerminator, arg == "--json" {
                index += 1
                continue
            }
            if !pastTerminator, arg == "--id" {
                idArg = try requireValue()
                index += 2
                continue
            }
            if !pastTerminator, arg == "--workspace" {
                wsArg = try requireValue()
                index += 2
                continue
            }
            if !pastTerminator, arg == "--window" {
                winArg = try requireValue()
                index += 2
                continue
            }
            if !pastTerminator, arg.hasPrefix("--id=") {
                let value = String(arg.dropFirst("--id=".count))
                guard !value.isEmpty else { throw CLIError(message: usage) }
                idArg = value
                index += 1
                continue
            }
            if !pastTerminator, arg.hasPrefix("--workspace=") {
                let value = String(arg.dropFirst("--workspace=".count))
                guard !value.isEmpty else { throw CLIError(message: usage) }
                wsArg = value
                index += 1
                continue
            }
            if !pastTerminator, arg.hasPrefix("--window=") {
                let value = String(arg.dropFirst("--window=".count))
                guard !value.isEmpty else { throw CLIError(message: usage) }
                winArg = value
                index += 1
                continue
            }
            if !pastTerminator, arg.hasPrefix("--") {
                throw CLIError(message: usage)
            }
            positional.append(arg)
            index += 1
        }

        guard positional.count <= 1 else {
            throw CLIError(message: usage)
        }
        guard let sub = positional.first?.lowercased() else {
            throw CLIError(message: usage)
        }
        let turnOn: Bool
        switch sub {
        case "on", "start", "show", "running", "busy":
            turnOn = true
        case "off", "stop", "hide", "done", "idle", "finished":
            turnOn = false
        default:
            throw CLIError(message: String(
                format: String(
                    localized: "cli.error.workspaceLoadingInvalidState",
                    defaultValue: "Invalid state '%@'. Expected on or off. %@"
                ),
                locale: .current,
                sub,
                usage
            ))
        }

        return WorkspaceLoadingArguments(
            turnOn: turnOn,
            id: idArg,
            workspace: wsArg,
            window: winArg
        )
    }

    /// `cmux workspace loading <on|off> [--id <name>]` toggles the workspace's
    /// loading spinner via the reserved `manual` lifecycle namespace.
    func runWorkspaceLoading(
        commandArgs: [String],
        client: SocketClient,
        windowId: String?,
        jsonOutput: Bool
    ) throws {
        let parsed = try parseWorkspaceLoadingArguments(commandArgs)
        let usage = workspaceLoadingUsage()

        let manual = AgentHibernationLifecycleStatusKeys.manualKey
        let key: String
        if let rawId = parsed.id?.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard !rawId.isEmpty else {
                throw CLIError(message: usage)
            }
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            guard rawId.unicodeScalars.allSatisfy(allowed.contains) else {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.error.workspaceLoadingInvalidId",
                        defaultValue: "Invalid --id '%@'. Use letters, digits, '.', '_', or '-' (no spaces)."
                    ),
                    locale: .current,
                    rawId
                ))
            }
            key = "\(manual):\(rawId)"
        } else {
            key = manual
        }

        let windowRaw = parsed.window ?? windowId
        let workspaceArg = parsed.workspace ?? Self.callerWorkspaceForSurfaceHandle(nil, windowRaw: windowRaw)
        let winId = try normalizeWindowHandle(windowRaw, client: client)
        let wsId = try resolveWorkspaceId(
            workspaceArg,
            client: client,
            windowHandle: winId
        )

        let response = try sendV1Command(
            "workspace_loading \(key) \(parsed.turnOn ? "on" : "off") --tab=\(wsId)",
            client: client
        )

        if jsonOutput {
            var before = false
            var after = false
            for part in response.split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let isOn = kv[1].trimmingCharacters(in: .whitespaces).uppercased() == "ON"
                if kv[0] == "before" { before = isOn }
                if kv[0] == "after" { after = isOn }
            }
            print(jsonString([
                "ok": true,
                "id": parsed.id ?? "",
                "workspace_id": wsId,
                "before": before,
                "after": after,
                "loading": after,
            ]))
        } else {
            print(response)
        }
    }
}
