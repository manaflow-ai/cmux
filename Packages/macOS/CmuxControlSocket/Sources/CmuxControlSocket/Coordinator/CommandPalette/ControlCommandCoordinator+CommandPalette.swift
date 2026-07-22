internal import Foundation

/// The live command-palette control domain.
extension ControlCommandCoordinator {
    /// A typed view of the command-palette slice of ``context``.
    var commandPaletteContext: (any ControlCommandPaletteContext)? {
        context as? any ControlCommandPaletteContext
    }

    /// Dispatches `palette.list` and `palette.run`.
    func handleCommandPalette(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "palette.list":
            return commandPaletteList(request.params)
        case "palette.run":
            return commandPaletteRun(request.params)
        default:
            return nil
        }
    }

    /// `palette.list` — list the exact live actions exposed by Cmd+Shift+P.
    func commandPaletteList(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = commandPaletteContext?.controlCommandPaletteList(
            routing: routingSelectors(params)
        ) ?? .windowNotFound
        switch resolution {
        case .windowNotFound:
            return .err(
                code: "not_found",
                message: String(
                    localized: "socket.palette.error.windowNotFound",
                    defaultValue: "Command palette window not found",
                    bundle: .main
                ),
                data: nil
            )
        case .listed(let windowID, let commands):
            return .ok(.object([
                "window_id": .string(windowID.uuidString),
                "count": .int(Int64(commands.count)),
                "commands": .array(commands.map(commandPalettePayload)),
            ]))
        }
    }

    /// `palette.run` — invoke the live handler for one stable action id.
    func commandPaletteRun(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let commandID = string(params, "command_id") else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.palette.error.missingCommandID",
                    defaultValue: "Missing 'command_id' parameter",
                    bundle: .main
                ),
                data: nil
            )
        }
        let resolution = commandPaletteContext?.controlCommandPaletteRun(
            routing: routingSelectors(params),
            commandID: commandID
        ) ?? .windowNotFound
        switch resolution {
        case .windowNotFound:
            return .err(
                code: "not_found",
                message: String(
                    localized: "socket.palette.error.windowNotFound",
                    defaultValue: "Command palette window not found",
                    bundle: .main
                ),
                data: nil
            )
        case .commandNotFound:
            return .err(
                code: "not_found",
                message: String(
                    localized: "socket.palette.error.commandNotFound",
                    defaultValue: "Command palette action not found in the current context",
                    bundle: .main
                ),
                data: .object(["command_id": .string(commandID)])
            )
        case .ran(let windowID, let command):
            return .ok(.object([
                "window_id": .string(windowID.uuidString),
                "command": commandPalettePayload(command),
            ]))
        }
    }

    /// Encodes one action description for both list and run responses.
    private func commandPalettePayload(_ command: ControlCommandPaletteItem) -> JSONValue {
        .object([
            "id": .string(command.id),
            "title": .string(command.title),
            "subtitle": .string(command.subtitle),
            "shortcut_hint": command.shortcutHint.map(JSONValue.string) ?? .null,
            "keywords": .array(command.keywords.map(JSONValue.string)),
            "dismiss_on_run": .bool(command.dismissOnRun),
        ])
    }
}
