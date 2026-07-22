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
        let strings = commandPaletteStrings
        let resolution = commandPaletteContext?.controlCommandPaletteList(
            routing: routingSelectors(params)
        ) ?? .windowNotFound
        switch resolution {
        case .windowNotFound:
            return .err(
                code: "not_found",
                message: strings.windowNotFound,
                data: nil
            )
        case .listed(let target, let commands):
            return .ok(.object([
                // Keep the original flat fields so existing clients can feed
                // them back as ordinary routing selectors. New clients should
                // echo `target` to `palette.run` as one immutable value.
                "window_id": .string(target.windowID.uuidString),
                "window_ref": ref(.window, target.windowID),
                "workspace_id": target.workspaceID.map { .string($0.uuidString) } ?? .null,
                "workspace_ref": ref(.workspace, target.workspaceID),
                "surface_id": target.panelID.map { .string($0.uuidString) } ?? .null,
                "surface_ref": ref(.surface, target.panelID),
                "target": commandPaletteTargetPayload(target),
                "count": .int(Int64(commands.count)),
                "commands": .array(commands.map(commandPalettePayload)),
            ]))
        }
    }

    /// `palette.run` — invoke the live handler for one stable action id.
    func commandPaletteRun(_ params: [String: JSONValue]) -> ControlCallResult {
        let strings = commandPaletteStrings
        guard let commandID = string(params, "command_id") else {
            return .err(
                code: "invalid_params",
                message: strings.missingCommandID,
                data: nil
            )
        }
        let arguments: [String: String]
        if let rawArguments = params["arguments"] {
            guard case .object(let object) = rawArguments else {
                return .err(
                    code: "invalid_params",
                    message: strings.argumentsMustBeStringObject,
                    data: nil
                )
            }
            var parsed: [String: String] = [:]
            parsed.reserveCapacity(object.count)
            for (name, value) in object {
                guard case .string(let stringValue) = value else {
                    return .err(
                        code: "invalid_params",
                        message: strings.argumentsMustBeStringObject,
                        data: .object(["argument": .string(name)])
                    )
                }
                parsed[name] = stringValue
            }
            arguments = parsed
        } else {
            arguments = [:]
        }
        let target: ControlCommandPaletteTarget?
        switch commandPaletteTargetRouting(params) {
        case .legacy:
            target = nil
        case .target(let exactTarget):
            target = exactTarget
        case .invalid:
            return .err(
                code: "invalid_params",
                message: strings.invalidTarget,
                data: nil
            )
        }
        let resolution: ControlCommandPaletteRunResolution
        if let target {
            resolution = commandPaletteContext?.controlCommandPaletteRun(
                target: target,
                commandID: commandID,
                arguments: arguments,
                workingDirectory: rawString(params, "cwd")
            ) ?? .windowNotFound
        } else {
            resolution = commandPaletteContext?.controlCommandPaletteRun(
                routing: routingSelectors(params),
                commandID: commandID,
                arguments: arguments,
                workingDirectory: rawString(params, "cwd")
            ) ?? .windowNotFound
        }
        switch resolution {
        case .windowNotFound:
            return .err(
                code: "not_found",
                message: strings.windowNotFound,
                data: nil
            )
        case .targetUnavailable:
            return .err(
                code: "target_unavailable",
                message: strings.targetUnavailable,
                data: target.map(commandPaletteTargetPayload)
            )
        case .commandNotFound:
            return .err(
                code: "not_found",
                message: strings.commandNotFound,
                data: .object(["command_id": .string(commandID)])
            )
        case .completed(let windowID, let command):
            return .ok(commandPaletteRunPayload(
                windowID: windowID,
                target: target,
                command: command,
                additions: ["status": .string("completed")]
            ))
        case .queued(let windowID, let command):
            return .ok(commandPaletteRunPayload(
                windowID: windowID,
                target: target,
                command: command,
                additions: ["status": .string("queued")]
            ))
        case .presented(let windowID, let command):
            return .ok(commandPaletteRunPayload(
                windowID: windowID,
                target: target,
                command: command,
                additions: ["status": .string("presented")]
            ))
        case .requiresArguments(let windowID, let command, let arguments):
            return .err(
                code: "invalid_params",
                message: String(
                    format: strings.missingArgumentsFormat,
                    arguments.map(\.name).joined(separator: ", ")
                ),
                data: commandPaletteRunPayload(
                    windowID: windowID,
                    target: target,
                    command: command,
                    additions: [
                        "required_arguments": .array(arguments.map(commandPaletteArgumentPayload)),
                    ]
                )
            )
        case .invalidArguments(let windowID, let command, let names):
            return .err(
                code: "invalid_params",
                message: String(
                    format: strings.unknownArgumentsFormat,
                    names.joined(separator: ", ")
                ),
                data: commandPaletteRunPayload(
                    windowID: windowID,
                    target: target,
                    command: command,
                    additions: ["unknown_arguments": .array(names.map(JSONValue.string))]
                )
            )
        case .invalidArgumentValues(let windowID, let command, let names):
            return .err(
                code: "invalid_params",
                message: String(
                    format: strings.invalidArgumentValuesFormat,
                    names.joined(separator: ", ")
                ),
                data: commandPaletteRunPayload(
                    windowID: windowID,
                    target: target,
                    command: command,
                    additions: ["invalid_arguments": .array(names.map(JSONValue.string))]
                )
            )
        case .failed(let windowID, let command, let code, let message):
            return .err(
                code: code,
                message: message,
                data: commandPaletteRunPayload(
                    windowID: windowID,
                    target: target,
                    command: command
                )
            )
        }
    }

    /// Uses app-resolved strings in production and stable English fallbacks
    /// when a partial test context omits the palette domain.
    private var commandPaletteStrings: ControlCommandPaletteStrings {
        commandPaletteContext?.controlCommandPaletteStrings() ?? ControlCommandPaletteStrings(
            windowNotFound: "Command palette window not found",
            targetUnavailable: "The command palette target is no longer available",
            missingCommandID: "Missing 'command_id' parameter",
            invalidTarget: "Invalid command palette target",
            argumentsMustBeStringObject: "'arguments' must be an object of string values",
            commandNotFound: "Command palette action not found in the current context",
            missingArgumentsFormat: "Missing required action arguments: %@",
            unknownArgumentsFormat: "Unknown action arguments: %@",
            invalidArgumentValuesFormat: "Invalid values for action arguments: %@"
        )
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
            "arguments": .array(command.arguments.map(commandPaletteArgumentPayload)),
        ])
    }

    /// Adds ref twins for every routed identity available at dispatch time so
    /// CLI `--id-format` can select refs, UUIDs, or both without losing the
    /// immutable UUID-only `target` echo contract.
    private func commandPaletteRunPayload(
        windowID: UUID,
        target: ControlCommandPaletteTarget?,
        command: ControlCommandPaletteItem,
        additions: [String: JSONValue] = [:]
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "window_id": .string(windowID.uuidString),
            "window_ref": ref(.window, windowID),
            "command": commandPalettePayload(command),
        ]
        if let target {
            payload["workspace_id"] = target.workspaceID.map { .string($0.uuidString) } ?? .null
            payload["workspace_ref"] = ref(.workspace, target.workspaceID)
            payload["surface_id"] = target.panelID.map { .string($0.uuidString) } ?? .null
            payload["surface_ref"] = ref(.surface, target.panelID)
            payload["target"] = commandPaletteTargetPayload(target)
        }
        for (key, value) in additions {
            payload[key] = value
        }
        return .object(payload)
    }

    /// Encodes the exact target identity returned by `palette.list` and
    /// accepted by `palette.run`.
    private func commandPaletteTargetPayload(_ target: ControlCommandPaletteTarget) -> JSONValue {
        .object([
            "window_id": .string(target.windowID.uuidString),
            "workspace_id": target.workspaceID.map { .string($0.uuidString) } ?? .null,
            "panel_id": target.panelID.map { .string($0.uuidString) } ?? .null,
        ])
    }

    /// Parses an immutable target returned by `palette.list`. Its presence is
    /// all-or-nothing: malformed or stale identifiers fail closed in the app
    /// instead of falling back to the newly focused workspace or panel.
    private func commandPaletteTargetRouting(
        _ params: [String: JSONValue]
    ) -> CommandPaletteTargetRouting {
        guard let rawTarget = params["target"] else { return .legacy }
        guard case .object(let target) = rawTarget,
              target["window_id"] != nil,
              target["workspace_id"] != nil,
              target["panel_id"] != nil,
              let windowID = uuid(target, "window_id") else {
            return .invalid
        }

        let workspaceID = uuid(target, "workspace_id")
        if hasNonNull(target, "workspace_id"), workspaceID == nil {
            return .invalid
        }
        let panelID = uuid(target, "panel_id")
        if hasNonNull(target, "panel_id"), panelID == nil {
            return .invalid
        }
        if panelID != nil, workspaceID == nil {
            return .invalid
        }

        return .target(ControlCommandPaletteTarget(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID
        ))
    }

    /// Encodes one static action argument contract.
    private func commandPaletteArgumentPayload(
        _ argument: ControlCommandPaletteArgument
    ) -> JSONValue {
        .object([
            "name": .string(argument.name),
            "type": .string(argument.type),
            "required": .bool(argument.required),
            "allows_empty": .bool(argument.allowsEmpty),
        ])
    }
}

private enum CommandPaletteTargetRouting {
    case legacy
    case target(ControlCommandPaletteTarget)
    case invalid
}
