import Darwin
import Foundation

extension CMUXCLI {
    private func agentFastPathUsage() -> String {
        "Usage: cmux agent <capture|send|send-key|list-panes|list-surfaces|batch> [flags]"
    }

    private func agentFastPathString(_ raw: Any?) -> String? {
        guard let raw, !(raw is NSNull) else { return nil }
        if let value = raw as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = raw as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private func agentFastPathString(_ spec: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = agentFastPathString(spec[key]) {
                return value
            }
        }
        return nil
    }

    private func agentFastPathBool(_ raw: Any?, default defaultValue: Bool = false) throws -> Bool {
        guard let raw, !(raw is NSNull) else { return defaultValue }
        if let value = raw as? Bool {
            return value
        }
        if let value = raw as? NSNumber {
            return value.boolValue
        }
        if let value = raw as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                break
            }
        }
        throw CLIError(message: "agent batch boolean fields must be true or false")
    }

    private func agentFastPathPositiveInt(_ raw: Any?, label: String) throws -> Int? {
        guard let raw, !(raw is NSNull) else { return nil }
        let value: Int?
        if let int = raw as? Int {
            value = int
        } else if let number = raw as? NSNumber {
            value = number.intValue
        } else if let string = raw as? String {
            value = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            value = nil
        }
        guard let value else {
            throw CLIError(message: "\(label) must be an integer")
        }
        guard value > 0 else {
            throw CLIError(message: "\(label) must be greater than 0")
        }
        return value
    }

    private func agentFastPathTargetParams(
        workspaceRaw: String?,
        surfaceRaw: String?,
        client: SocketClient,
        windowOverride: String?
    ) throws -> [String: Any] {
        let env = ProcessInfo.processInfo.environment
        let workspaceArg = workspaceRaw ?? (windowOverride == nil ? env["CMUX_WORKSPACE_ID"] : nil)
        let surfaceArg = surfaceRaw ?? (workspaceRaw == nil && windowOverride == nil ? env["CMUX_SURFACE_ID"] : nil)

        var params: [String: Any] = [:]
        let workspaceId = try normalizeWorkspaceHandle(workspaceArg, client: client)
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        let surfaceId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: workspaceId)
        if let surfaceId {
            params["surface_id"] = surfaceId
        }
        return params
    }

    private func agentFastPathCapturePayload(
        workspaceRaw: String?,
        surfaceRaw: String?,
        scrollback: Bool,
        lines: Int?,
        client: SocketClient,
        windowOverride: String?
    ) throws -> [String: Any] {
        var params = try agentFastPathTargetParams(
            workspaceRaw: workspaceRaw,
            surfaceRaw: surfaceRaw,
            client: client,
            windowOverride: windowOverride
        )
        if scrollback {
            params["scrollback"] = true
        }
        if let lines {
            params["lines"] = lines
            params["scrollback"] = true
        }
        return try client.sendV2(method: "surface.read_text", params: params)
    }

    private func agentFastPathSendPayload(
        workspaceRaw: String?,
        surfaceRaw: String?,
        text: String,
        appendEnter: Bool,
        client: SocketClient,
        windowOverride: String?
    ) throws -> [String: Any] {
        var params = try agentFastPathTargetParams(
            workspaceRaw: workspaceRaw,
            surfaceRaw: surfaceRaw,
            client: client,
            windowOverride: windowOverride
        )
        params["text"] = appendEnter ? text + "\r" : text
        return try client.sendV2(method: "surface.send_text", params: params)
    }

    private func agentFastPathSendKeyPayload(
        workspaceRaw: String?,
        surfaceRaw: String?,
        key: String,
        client: SocketClient,
        windowOverride: String?
    ) throws -> [String: Any] {
        var params = try agentFastPathTargetParams(
            workspaceRaw: workspaceRaw,
            surfaceRaw: surfaceRaw,
            client: client,
            windowOverride: windowOverride
        )
        params["key"] = key
        return try client.sendV2(method: "surface.send_key", params: params)
    }

    private func agentFastPathListPanesPayload(
        workspaceRaw: String?,
        client: SocketClient,
        windowOverride: String?
    ) throws -> [String: Any] {
        let workspaceArg = workspaceRaw ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        var params: [String: Any] = [:]
        let workspaceId = try normalizeWorkspaceHandle(workspaceArg, client: client)
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        return try client.sendV2(method: "pane.list", params: params)
    }

    private func agentFastPathListSurfacesPayload(
        workspaceRaw: String?,
        client: SocketClient,
        windowOverride: String?
    ) throws -> [String: Any] {
        let workspaceArg = workspaceRaw ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        var params: [String: Any] = [:]
        let workspaceId = try normalizeWorkspaceHandle(workspaceArg, client: client)
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        return try client.sendV2(method: "surface.list", params: params)
    }

    private func agentFastPathBatchInput(commandArgs: [String]) throws -> String {
        let parsed = try agentFastPathParseArgs(
            commandArgs,
            commandName: "agent batch",
            valueOptions: ["--file"]
        )
        let fileArg = parsed.options["--file"]
        if let fileArg {
            return try String(contentsOfFile: resolvePath(fileArg), encoding: .utf8)
        }

        let inline = parsed.positionals
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !inline.isEmpty {
            return inline
        }

        guard isatty(STDIN_FILENO) == 0 else {
            throw CLIError(message: "agent batch requires JSON via --file, an argument, or stdin")
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "agent batch stdin must be UTF-8 JSON")
        }
        return text
    }

    private func agentFastPathBatchOperations(from text: String) throws -> [[String: Any]] {
        guard let data = text.data(using: .utf8) else {
            throw CLIError(message: "agent batch input must be UTF-8 JSON")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw CLIError(message: "agent batch input must be valid JSON: \(error.localizedDescription)")
        }
        if let operations = object as? [[String: Any]] {
            return operations
        }
        if let dictionary = object as? [String: Any] {
            if let operations = dictionary["ops"] as? [[String: Any]] {
                return operations
            }
            if let operations = dictionary["operations"] as? [[String: Any]] {
                return operations
            }
        }
        throw CLIError(message: "agent batch JSON must be an array or an object with ops/operations")
    }

    private func runAgentFastPathBatchOperation(
        _ spec: [String: Any],
        client: SocketClient,
        windowOverride: String?
    ) throws -> [String: Any] {
        guard let op = agentFastPathString(spec, keys: ["op", "command"])?.lowercased() else {
            throw CLIError(message: "agent batch operation missing op")
        }
        let workspace = agentFastPathString(spec, keys: ["workspace", "workspace_id", "workspace_ref"])
        let surface = agentFastPathString(spec, keys: ["surface", "surface_id", "surface_ref", "panel", "panel_id", "panel_ref"])

        switch op {
        case "capture", "read", "read-screen":
            let lines = try agentFastPathPositiveInt(spec["lines"], label: "lines")
            let scrollback = try agentFastPathBool(spec["scrollback"], default: lines != nil)
            return try agentFastPathCapturePayload(
                workspaceRaw: workspace,
                surfaceRaw: surface,
                scrollback: scrollback,
                lines: lines,
                client: client,
                windowOverride: windowOverride
            )

        case "send":
            guard let text = (spec["text"] as? String) ?? (spec["input"] as? String),
                  !text.isEmpty else {
                throw CLIError(message: "agent batch send operation requires text")
            }
            let appendEnter = try agentFastPathBool(spec["enter"], default: false)
            return try agentFastPathSendPayload(
                workspaceRaw: workspace,
                surfaceRaw: surface,
                text: text,
                appendEnter: appendEnter,
                client: client,
                windowOverride: windowOverride
            )

        case "send-key", "key":
            guard let key = agentFastPathString(spec, keys: ["key"]) else {
                throw CLIError(message: "agent batch send-key operation requires key")
            }
            return try agentFastPathSendKeyPayload(
                workspaceRaw: workspace,
                surfaceRaw: surface,
                key: key,
                client: client,
                windowOverride: windowOverride
            )

        case "list-panes", "panes":
            return try agentFastPathListPanesPayload(
                workspaceRaw: workspace,
                client: client,
                windowOverride: windowOverride
            )

        case "list-surfaces", "surfaces", "list-panels", "panels":
            return try agentFastPathListSurfacesPayload(
                workspaceRaw: workspace,
                client: client,
                windowOverride: windowOverride
            )

        default:
            throw CLIError(message: "Unsupported agent batch op: \(op)")
        }
    }

    private func runAgentFastPathBatch(
        commandArgs: [String],
        client: SocketClient,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let text = try agentFastPathBatchInput(commandArgs: commandArgs)
        let operations = try agentFastPathBatchOperations(from: text)
        var allSucceeded = true
        let results = operations.enumerated().map { index, spec -> [String: Any] in
            let rawName = agentFastPathString(spec, keys: ["op", "command"]) ?? ""
            do {
                let result = try runAgentFastPathBatchOperation(
                    spec,
                    client: client,
                    windowOverride: windowOverride
                )
                return [
                    "index": index,
                    "ok": true,
                    "op": rawName,
                    "result": formatIDs(result, mode: idFormat)
                ]
            } catch {
                allSucceeded = false
                return [
                    "index": index,
                    "ok": false,
                    "op": rawName,
                    "error": String(describing: error)
                ]
            }
        }
        print(jsonString([
            "ok": allSucceeded,
            "results": results
        ]))
        if !allSucceeded {
            throw CLIError(message: "agent batch completed with one or more failed operations", exitCode: 1)
        }
    }

    private func printAgentFastPathPayload(_ payload: [String: Any], idFormat: CLIIDFormat) {
        print(jsonString(formatIDs(payload, mode: idFormat)))
    }

    func runAgentFastPathCommand(
        commandArgs: [String],
        client: SocketClient,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        guard let rawSubcommand = commandArgs.first else {
            print(agentFastPathUsage())
            return
        }
        let subcommand = rawSubcommand.lowercased()
        let rawArgs = Array(commandArgs.dropFirst())

        switch subcommand {
        case "-h", "--help", "help":
            print(agentFastPathUsage())

        case "capture", "read", "read-screen":
            let parsed = try agentFastPathParseArgs(
                rawArgs,
                commandName: "agent capture",
                flags: ["--raw", "--scrollback"],
                valueOptions: ["--workspace", "--surface", "--lines"]
            )
            let rawOutput = parsed.flags.contains("--raw")
            let includeScrollback = parsed.flags.contains("--scrollback")
            if !parsed.positionals.isEmpty {
                throw CLIError(message: "agent capture: unexpected arguments: \(parsed.positionals.joined(separator: " "))")
            }
            let lines = try agentFastPathPositiveInt(parsed.options["--lines"], label: "--lines")
            let payload = try agentFastPathCapturePayload(
                workspaceRaw: parsed.options["--workspace"],
                surfaceRaw: parsed.options["--surface"],
                scrollback: includeScrollback,
                lines: lines,
                client: client,
                windowOverride: windowOverride
            )
            if rawOutput {
                print((payload["text"] as? String) ?? "")
            } else {
                printAgentFastPathPayload(payload, idFormat: idFormat)
            }

        case "send":
            let parsed = try agentFastPathParseArgs(
                rawArgs,
                commandName: "agent send",
                flags: ["--enter"],
                valueOptions: ["--workspace", "--surface"]
            )
            let appendEnter = parsed.flags.contains("--enter")
            let rawText = parsed.positionals.joined(separator: " ")
            guard !rawText.isEmpty else {
                throw CLIError(message: "agent send requires text")
            }
            let payload = try agentFastPathSendPayload(
                workspaceRaw: parsed.options["--workspace"],
                surfaceRaw: parsed.options["--surface"],
                text: agentFastPathUnescapeSendText(rawText),
                appendEnter: appendEnter,
                client: client,
                windowOverride: windowOverride
            )
            printAgentFastPathPayload(payload, idFormat: idFormat)

        case "send-key", "key":
            let parsed = try agentFastPathParseArgs(
                rawArgs,
                commandName: "agent send-key",
                valueOptions: ["--workspace", "--surface"]
            )
            guard let key = parsed.positionals.first, !key.isEmpty else {
                throw CLIError(message: "agent send-key requires a key")
            }
            guard parsed.positionals.count == 1 else {
                throw CLIError(message: "agent send-key: unexpected arguments: \(parsed.positionals.dropFirst().joined(separator: " "))")
            }
            let payload = try agentFastPathSendKeyPayload(
                workspaceRaw: parsed.options["--workspace"],
                surfaceRaw: parsed.options["--surface"],
                key: key,
                client: client,
                windowOverride: windowOverride
            )
            printAgentFastPathPayload(payload, idFormat: idFormat)

        case "list-panes", "panes":
            let parsed = try agentFastPathParseArgs(
                rawArgs,
                commandName: "agent list-panes",
                valueOptions: ["--workspace"]
            )
            if !parsed.positionals.isEmpty {
                throw CLIError(message: "agent list-panes: unexpected arguments: \(parsed.positionals.joined(separator: " "))")
            }
            let payload = try agentFastPathListPanesPayload(
                workspaceRaw: parsed.options["--workspace"],
                client: client,
                windowOverride: windowOverride
            )
            printAgentFastPathPayload(payload, idFormat: idFormat)

        case "list-surfaces", "surfaces", "list-panels", "panels":
            let parsed = try agentFastPathParseArgs(
                rawArgs,
                commandName: "agent list-surfaces",
                valueOptions: ["--workspace"]
            )
            if !parsed.positionals.isEmpty {
                throw CLIError(message: "agent list-surfaces: unexpected arguments: \(parsed.positionals.joined(separator: " "))")
            }
            let payload = try agentFastPathListSurfacesPayload(
                workspaceRaw: parsed.options["--workspace"],
                client: client,
                windowOverride: windowOverride
            )
            printAgentFastPathPayload(payload, idFormat: idFormat)

        case "batch":
            try runAgentFastPathBatch(
                commandArgs: rawArgs,
                client: client,
                idFormat: idFormat,
                windowOverride: windowOverride
            )

        default:
            throw CLIError(message: "Unknown agent command: \(rawSubcommand)")
        }
    }
}
