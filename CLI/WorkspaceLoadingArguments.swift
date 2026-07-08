import Foundation

struct WorkspaceLoadingArguments {
    let turnOn: Bool
    let id: String?
    let workspace: String?
    let window: String?
}

extension CMUXCLI {
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
}
