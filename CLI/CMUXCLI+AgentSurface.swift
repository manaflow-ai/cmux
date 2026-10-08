import Foundation

/// Agent-facing topology and mutation commands.
///
/// This surface is deliberately JSON-first. Every mutating operation returns
/// the socket result together with a fresh `system.tree` snapshot, so an agent
/// can verify the resulting selection without taking a screenshot.
extension CMUXCLI {
    static var agentSurfaceHelp: String {
        String(localized: "cli.help.agents", defaultValue: """
        Usage: cmux agents <snapshot|workspace|tab|surface|palette|dialog|mcp> [options]

        Drive cmux from an agent with stable window, workspace, pane, tab and
        surface ids. Mutations return a receipt containing the result and the
        post-action topology snapshot.

        Commands:
          snapshot [--all] [--window <id|ref|index>] [--workspace <id|ref|index>]
          workspace select <id|ref|index> [--window <id|ref|index>]
          workspace create [--name <title>] [--cwd <path>] [--command <text>] [--focus <true|false>] [--window <id|ref|index>]
          tab select <id|ref|index> [--window <id|ref|index>] [--workspace <id|ref|index>]
          surface focus <id|ref|index> [--window <id|ref|index>] [--workspace <id|ref|index>]
          surface split <left|right|up|down> [--surface <id|ref|index>] [--window <id|ref|index>] [--workspace <id|ref|index>] [--command <text>]
          palette toggle [--window <id|ref|index>]
          dialog list
          dialog answer <request-id> (--mode <once|always|all|bypass|deny> | --selection <value>... | --plan-mode <mode>)
          mcp

        `cmux agents mcp` serves the same operations as MCP tools over stdio.
        """)
    }

    /// Handles `cmux agents` and returns `false` for no other command.
    func runAgentSurfaceCommandIfMatched(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws -> Bool {
        guard commandArgs.first?.lowercased() == "agents" else { return false }
        let rest = Array(commandArgs.dropFirst())
        if rest.contains("--help") || rest.contains("-h") || rest.isEmpty {
            print(Self.agentSurfaceHelp)
            return true
        }
        if rest.first?.lowercased() == "mcp" {
            let mcpArgs = Array(rest.dropFirst())
            guard mcpArgs.isEmpty else {
                throw CLIError(message: "agents mcp does not accept arguments")
            }
            try runAgentSurfaceMCP(client: client)
            return true
        }

        let receipt = try agentSurfaceReceipt(
            arguments: rest,
            client: client,
            idFormat: idFormat,
            windowOverride: windowOverride
        )
        // The agent surface is structured even without --json. This makes a
        // direct invocation safe to hand to an agent without another flag.
        _ = jsonOutput
        print(jsonString(receipt))
        return true
    }

    /// Runs one agent-surface operation and returns its post-action receipt.
    func agentSurfaceReceipt(
        arguments: [String],
        client: SocketClient,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws -> [String: Any] {
        guard let family = arguments.first?.lowercased() else {
            throw CLIError(message: Self.agentSurfaceHelp)
        }
        let rest = Array(arguments.dropFirst())
        switch family {
        case "snapshot":
            let parsed = try agentSurfaceContext(rest, client: client, windowOverride: windowOverride)
            let state = try agentSurfaceSnapshot(
                client: client,
                context: parsed,
                idFormat: idFormat
            )
            return [
                "schema_version": 1,
                "action": "snapshot",
                "state": state,
            ]

        case "workspace":
            guard let verb = rest.first?.lowercased() else {
                throw CLIError(message: "agents workspace requires select or create")
            }
            let tail = Array(rest.dropFirst())
            switch verb {
            case "select":
                let (target, args) = try agentSurfaceTarget(tail, option: "--workspace")
                guard let target else { throw CLIError(message: "agents workspace select requires a workspace") }
                let context = try agentSurfaceContext(args, client: client, windowOverride: windowOverride)
                guard let workspaceID = try normalizeWorkspaceHandle(
                    target,
                    client: client,
                    windowHandle: context.windowID
                ) else {
                    throw CLIError(message: "agents workspace select requires a valid workspace")
                }
                var params: [String: Any] = ["workspace_id": workspaceID]
                if let windowID = context.windowID { params["window_id"] = windowID }
                let result = try client.sendV2(method: "workspace.select", params: params)
                return try agentSurfaceReceipt(
                    action: "workspace.select",
                    result: result,
                    client: client,
                    context: context,
                    idFormat: idFormat
                )
            case "create":
                let (params, context) = try agentSurfaceWorkspaceCreateParams(
                    tail,
                    client: client,
                    windowOverride: windowOverride
                )
                let result = try client.sendV2(method: "workspace.create", params: params)
                return try agentSurfaceReceipt(
                    action: "workspace.create",
                    result: result,
                    client: client,
                    context: context,
                    idFormat: idFormat
                )
            default:
                throw CLIError(message: "Unknown agents workspace command '\(verb)'")
            }

        case "tab", "surface":
            let expectedVerb = family == "tab" ? "select" : "focus"
            guard let verb = rest.first?.lowercased() else {
                let allowed = family == "surface" ? "focus or split" : "select"
                throw CLIError(message: "agents \(family) requires \(allowed)")
            }
            guard verb == expectedVerb || (family == "surface" && verb == "split") else {
                throw CLIError(message: "agents \(family) does not support '\(verb)'")
            }
            if verb == "split" {
                let (direction, args) = try agentSurfaceTarget(Array(rest.dropFirst()), option: nil)
                guard let direction, ["left", "right", "up", "down"].contains(direction.lowercased()) else {
                    throw CLIError(message: "agents surface split requires left, right, up, or down")
                }
                let parsed = try agentSurfaceSplitParams(
                    args,
                    direction: direction,
                    client: client,
                    windowOverride: windowOverride
                )
                let result = try client.sendV2(method: "surface.split", params: parsed.params)
                return try agentSurfaceReceipt(
                    action: "surface.split",
                    result: result,
                    client: client,
                    context: parsed.context,
                    idFormat: idFormat
                )
            }
            let (target, args) = try agentSurfaceTarget(Array(rest.dropFirst()), option: family == "tab" ? "--tab" : "--surface")
            guard let target else { throw CLIError(message: "agents \(family) \(verb) requires a target") }
            let context = try agentSurfaceContext(args, client: client, windowOverride: windowOverride)
            guard !context.allWindows else {
                throw CLIError(message: "agents \(family) \(verb) cannot use --all")
            }
            let canonical = target.lowercased().hasPrefix("tab:")
                ? "surface:" + String(target.dropFirst("tab:".count))
                : target
            guard let surfaceID = try normalizeSurfaceHandle(
                canonical,
                client: client,
                workspaceHandle: context.workspaceID,
                windowHandle: context.windowID
            ) else {
                throw CLIError(message: "agents \(family) \(verb) requires a target")
            }
            var params: [String: Any] = ["surface_id": surfaceID]
            if let windowID = context.windowID { params["window_id"] = windowID }
            if let workspaceID = context.workspaceID { params["workspace_id"] = workspaceID }
            let result = try client.sendV2(method: "surface.focus", params: params)
            return try agentSurfaceReceipt(
                action: "\(family).\(verb)",
                result: result,
                client: client,
                context: context,
                idFormat: idFormat
            )

        case "palette":
            guard rest.first?.lowercased() == "toggle" else {
                throw CLIError(message: "agents palette requires toggle")
            }
            let context = try agentSurfaceContext(Array(rest.dropFirst()), client: client, windowOverride: windowOverride)
            guard !context.allWindows, context.workspaceID == nil else {
                throw CLIError(message: "agents palette toggle accepts only --window")
            }
            var params: [String: Any] = [:]
            if let windowID = context.windowID { params["window_id"] = windowID }
            let result = try client.sendV2(method: "command_palette.toggle", params: params)
            return try agentSurfaceReceipt(
                action: "palette.toggle",
                result: result,
                client: client,
                context: context,
                idFormat: idFormat
            )

        case "dialog":
            guard let verb = rest.first?.lowercased() else {
                throw CLIError(message: "agents dialog requires list or answer")
            }
            switch verb {
            case "list":
                let listArgs = Array(rest.dropFirst())
                guard listArgs.allSatisfy({ $0 == "--all" }) else {
                    throw CLIError(message: "agents dialog list accepts only --all")
                }
                let pendingOnly = !listArgs.contains("--all")
                let result = try client.sendV2(method: "feed.list", params: ["pending_only": pendingOnly])
                return [
                    "schema_version": 1,
                    "action": "dialog.list",
                    "result": formatIDs(result, mode: idFormat),
                ]
            case "answer":
                let (requestID, mode, selections, planMode, feedback) = try agentSurfaceDialogAnswer(Array(rest.dropFirst()))
                var params: [String: Any] = ["request_id": requestID]
                let method: String
                if let mode {
                    method = "feed.permission.reply"
                    params["mode"] = mode
                } else if let planMode {
                    method = "feed.exit_plan.reply"
                    params["mode"] = planMode
                    if let feedback { params["feedback"] = feedback }
                } else {
                    method = "feed.question.reply"
                    params["selections"] = selections ?? []
                }
                let result = try client.sendV2(method: method, params: params)
                let context = try agentSurfaceContext([], client: client, windowOverride: windowOverride)
                return try agentSurfaceReceipt(
                    action: "dialog.answer",
                    result: result,
                    client: client,
                    context: context,
                    idFormat: idFormat
                )
            default:
                throw CLIError(message: "Unknown agents dialog command '\(verb)'")
            }

        default:
            throw CLIError(message: "Unknown agents command '\(family)'. Run `cmux agents --help`.")
        }
    }

    private struct AgentSurfaceContext {
        let windowID: String?
        let workspaceID: String?
        let allWindows: Bool
    }

    private func agentSurfaceContext(
        _ args: [String],
        client: SocketClient,
        windowOverride: String?
    ) throws -> AgentSurfaceContext {
        var rest = args
        var allWindows = false
        if let index = rest.firstIndex(of: "--all") {
            allWindows = true
            rest.remove(at: index)
        }
        let (workspaceRaw, afterWorkspace) = parseOption(rest, name: "--workspace")
        let (windowRaw, afterWindow) = parseOption(afterWorkspace, name: "--window")
        guard afterWindow.isEmpty else {
            throw CLIError(message: "agents: unexpected argument '\(afterWindow[0])'")
        }
        if let windowRaw, windowRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIError(message: "agents: --window requires a value")
        }
        if let windowOverride, windowOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIError(message: "agents: --window requires a value")
        }
        if let workspaceRaw, workspaceRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIError(message: "agents: --workspace requires a value")
        }
        let windowID = try normalizeWindowHandle(windowRaw ?? windowOverride, client: client)
        let workspaceID = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowID)
        if allWindows && (windowID != nil || workspaceID != nil) {
            throw CLIError(message: "agents: --all cannot be combined with --window or --workspace")
        }
        return AgentSurfaceContext(windowID: windowID, workspaceID: workspaceID, allWindows: allWindows)
    }

    private func agentSurfaceSnapshot(
        client: SocketClient,
        context: AgentSurfaceContext,
        idFormat: CLIIDFormat
    ) throws -> Any {
        var params: [String: Any] = ["all_windows": context.allWindows]
        if let windowID = context.windowID { params["window_id"] = windowID }
        if let workspaceID = context.workspaceID { params["workspace_id"] = workspaceID }
        let payload = try client.sendV2(method: "system.tree", params: params)
        return formatWorkspaceInspectionIDs(payload, mode: idFormat, preserveStableIDs: true)
    }

    private func agentSurfaceReceipt(
        action: String,
        result: [String: Any],
        client: SocketClient,
        context: AgentSurfaceContext,
        idFormat: CLIIDFormat
    ) throws -> [String: Any] {
        [
            "schema_version": 1,
            "action": action,
            "result": formatIDs(result, mode: idFormat),
            "state": try agentSurfaceSnapshot(client: client, context: context, idFormat: idFormat),
        ]
    }

    private func agentSurfaceTarget(
        _ args: [String],
        option: String?
    ) throws -> (String?, [String]) {
        guard let option else {
            guard let first = args.first else { return (nil, []) }
            return (first, Array(args.dropFirst()))
        }
        let (value, remaining) = parseOption(args, name: option)
        if let value { return (value, remaining) }
        guard let first = remaining.first, !first.hasPrefix("--") else { return (nil, remaining) }
        return (first, Array(remaining.dropFirst()))
    }

    private func agentSurfaceWorkspaceCreateParams(
        _ args: [String],
        client: SocketClient,
        windowOverride: String?
    ) throws -> ([String: Any], AgentSurfaceContext) {
        let (name, rem0) = parseOption(args, name: "--name")
        let (cwd, rem1) = parseOption(rem0, name: "--cwd")
        let (command, rem2) = parseOption(rem1, name: "--command")
        let (focus, rem3) = parseOption(rem2, name: "--focus")
        let (windowRaw, remaining) = parseOption(rem3, name: "--window")
        guard remaining.isEmpty else { throw CLIError(message: "agents workspace create: unexpected argument '\(remaining[0])'") }
        if let windowRaw, windowRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIError(message: "agents workspace create: --window requires a value")
        }
        if let windowOverride, windowOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIError(message: "agents workspace create: --window requires a value")
        }
        let windowID = try normalizeWindowHandle(windowRaw ?? windowOverride, client: client)
        var params: [String: Any] = [:]
        if let windowID { params["window_id"] = windowID }
        if let name { params["title"] = name }
        if let cwd { params["cwd"] = resolvePath(cwd) }
        if let command, !command.isEmpty { params["initial_input"] = command + "\r" }
        if let focus { params["focus"] = try parseAgentSurfaceBool(focus, name: "--focus") }
        return (params, AgentSurfaceContext(windowID: windowID, workspaceID: nil, allWindows: false))
    }

    private func agentSurfaceSplitParams(
        _ args: [String],
        direction: String,
        client: SocketClient,
        windowOverride: String?
    ) throws -> (params: [String: Any], context: AgentSurfaceContext) {
        let (surfaceRaw, rem0) = parseOption(args, name: "--surface")
        let (workspaceRaw, rem1) = parseOption(rem0, name: "--workspace")
        let (command, rem2) = parseOption(rem1, name: "--command")
        let (focus, rem3) = parseOption(rem2, name: "--focus")
        let (windowRaw, remaining) = parseOption(rem3, name: "--window")
        guard remaining.isEmpty else { throw CLIError(message: "agents surface split: unexpected argument '\(remaining[0])'") }
        if let windowRaw, windowRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIError(message: "agents surface split: --window requires a value")
        }
        if let workspaceRaw, workspaceRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIError(message: "agents surface split: --workspace requires a value")
        }
        if let windowOverride, windowOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIError(message: "agents surface split: --window requires a value")
        }
        let windowID = try normalizeWindowHandle(windowRaw ?? windowOverride, client: client)
        let workspaceID = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowID, allowCurrent: true)
        let surfaceID = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceID, windowHandle: windowID)
        var params: [String: Any] = ["direction": direction.lowercased()]
        if let windowID { params["window_id"] = windowID }
        if let workspaceID { params["workspace_id"] = workspaceID }
        if let surfaceID { params["surface_id"] = surfaceID }
        if let command, !command.isEmpty { params["initial_input"] = command + "\r" }
        if let focus { params["focus"] = try parseAgentSurfaceBool(focus, name: "--focus") }
        return (params, AgentSurfaceContext(windowID: windowID, workspaceID: workspaceID, allWindows: false))
    }

    private func parseAgentSurfaceBool(_ raw: String, name: String) throws -> Bool {
        guard let value = parseBoolString(raw) else {
            throw CLIError(message: "\(name) must be true or false")
        }
        return value
    }

    private func agentSurfaceDialogAnswer(
        _ args: [String]
    ) throws -> (requestID: String, mode: String?, selections: [String]?, planMode: String?, feedback: String?) {
        guard let requestID = args.first, !requestID.hasPrefix("--") else {
            throw CLIError(message: "agents dialog answer requires a request id")
        }
        let rest = Array(args.dropFirst())
        let (mode, rem0) = parseOption(rest, name: "--mode")
        let (planMode, rem1) = parseOption(rem0, name: "--plan-mode")
        let (feedback, rem2) = parseOption(rem1, name: "--feedback")
        let (selections, remaining) = try parseAgentSurfaceOptionValues(
            rem2,
            names: ["--selection", "--selections"]
        )
        guard remaining.isEmpty else {
            throw CLIError(message: "agents dialog answer: unexpected argument '\(remaining[0])'")
        }
        let responseKinds = [mode != nil, planMode != nil, !selections.isEmpty].filter { $0 }.count
        guard responseKinds == 1 else {
            throw CLIError(message: "agents dialog answer requires --mode, --plan-mode, or --selection")
        }
        if let mode {
            guard feedback == nil else {
                throw CLIError(message: "agents dialog answer: --feedback requires --plan-mode")
            }
            return (requestID, mode, nil, nil, nil)
        }
        if let planMode { return (requestID, nil, nil, planMode, feedback) }
        return (requestID, nil, selections, nil, nil)
    }

    private func parseAgentSurfaceOptionValues(
        _ args: [String],
        names: [String]
    ) throws -> (values: [String], remaining: [String]) {
        var values: [String] = []
        var remaining: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if let name = names.first(where: { arg == $0 }) {
                guard index + 1 < args.count else {
                    throw CLIError(message: "\(name) requires a value")
                }
                values.append(args[index + 1])
                index += 2
                continue
            }
            if let name = names.first(where: { arg.hasPrefix("\($0)=") }) {
                values.append(String(arg.dropFirst(name.count + 1)))
                index += 1
                continue
            }
            remaining.append(arg)
            index += 1
        }
        return (values, remaining)
    }

    private func appendAgentSurfaceScope(
        _ arguments: [String: Any],
        to command: inout [String],
        includeWorkspace: Bool
    ) throws {
        if let window = arguments["window"] {
            guard let window = window as? String, !window.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError(message: "window must be a non-empty handle")
            }
            command += ["--window", window]
        }
        if includeWorkspace, let workspace = arguments["workspace"] {
            guard let workspace = workspace as? String, !workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError(message: "workspace must be a non-empty handle")
            }
            command += ["--workspace", workspace]
        }
    }

    private func runAgentSurfaceMCP(client: SocketClient) throws {
        let server = AgentSurfaceMCPServer(version: resolvedVersionInfo()["CFBundleShortVersionString"] ?? "dev") { [self] name, arguments in
            var command: [String]
            switch name {
            case "snapshot":
                command = ["snapshot"]
                if arguments["all"] as? Bool == true { command.append("--all") }
                try appendAgentSurfaceScope(arguments, to: &command, includeWorkspace: true)
            case "workspace_select":
                guard let workspace = arguments["workspace"] as? String else {
                    throw CLIError(message: "workspace_select needs workspace")
                }
                command = ["workspace", "select", workspace]
                try appendAgentSurfaceScope(arguments, to: &command, includeWorkspace: false)
            case "workspace_create":
                command = ["workspace", "create"]
                if let name = arguments["name"] as? String { command += ["--name", name] }
                if let cwd = arguments["cwd"] as? String { command += ["--cwd", cwd] }
                if let initialCommand = arguments["command"] as? String { command += ["--command", initialCommand] }
                if let focus = arguments["focus"] as? Bool { command += ["--focus", focus ? "true" : "false"] }
                try appendAgentSurfaceScope(arguments, to: &command, includeWorkspace: false)
            case "tab_select":
                guard let tab = arguments["tab"] as? String else {
                    throw CLIError(message: "tab_select needs tab")
                }
                command = ["tab", "select", tab]
                try appendAgentSurfaceScope(arguments, to: &command, includeWorkspace: true)
            case "surface_focus":
                guard let surface = arguments["surface"] as? String else {
                    throw CLIError(message: "surface_focus needs surface")
                }
                command = ["surface", "focus", surface]
                try appendAgentSurfaceScope(arguments, to: &command, includeWorkspace: true)
            case "surface_split":
                guard let direction = arguments["direction"] as? String else {
                    throw CLIError(message: "surface_split needs direction")
                }
                command = ["surface", "split", direction]
                if let surface = arguments["surface"] as? String { command += ["--surface", surface] }
                if let initialCommand = arguments["command"] as? String { command += ["--command", initialCommand] }
                if let focus = arguments["focus"] as? Bool { command += ["--focus", focus ? "true" : "false"] }
                try appendAgentSurfaceScope(arguments, to: &command, includeWorkspace: true)
            case "palette_toggle":
                command = ["palette", "toggle"]
                try appendAgentSurfaceScope(arguments, to: &command, includeWorkspace: false)
            case "dialog_list":
                command = ["dialog", "list"]
                if arguments["all"] as? Bool == true { command.append("--all") }
            case "dialog_answer":
                guard let requestID = arguments["request_id"] as? String else {
                    throw CLIError(message: "dialog_answer needs request_id")
                }
                command = ["dialog", "answer", requestID]
                if let mode = arguments["mode"] as? String { command += ["--mode", mode] }
                if let planMode = arguments["plan_mode"] as? String { command += ["--plan-mode", planMode] }
                if let selection = arguments["selection"] as? String { command += ["--selection", selection] }
                if let selections = arguments["selections"] as? [String] {
                    for selection in selections { command += ["--selection", selection] }
                }
                if let feedback = arguments["feedback"] as? String { command += ["--feedback", feedback] }
            default:
                throw CLIError(message: "Unknown agent surface tool: \(name)")
            }
            let receipt = try agentSurfaceReceipt(
                arguments: command,
                client: client,
                idFormat: .both,
                windowOverride: nil
            )
            return .text(jsonString(receipt))
        }
        server.run()
    }
}

/// Minimal line-delimited MCP server for the agent surface.
struct AgentSurfaceMCPServer {
    struct ToolResult {
        let content: [[String: Any]]
        let isError: Bool
        static func text(_ text: String, isError: Bool = false) -> ToolResult {
            ToolResult(content: [["type": "text", "text": text]], isError: isError)
        }
    }

    let version: String
    let callTool: (String, [String: Any]) throws -> ToolResult

    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let tools: [[String: Any]] = [
        ["name": "snapshot", "description": "Return windows, workspaces, panes, tabs, surfaces, focus and selection.", "inputSchema": ["type": "object", "properties": ["all": ["type": "boolean"], "window": ["type": "string"], "workspace": ["type": "string"]]] as [String: Any]],
        ["name": "workspace_select", "description": "Select a workspace and return the resulting topology.", "inputSchema": ["type": "object", "properties": ["workspace": ["type": "string"], "window": ["type": "string"]], "required": ["workspace"]] as [String: Any]],
        ["name": "workspace_create", "description": "Create a workspace and return the resulting topology.", "inputSchema": ["type": "object", "properties": ["name": ["type": "string"], "cwd": ["type": "string"], "command": ["type": "string"], "focus": ["type": "boolean"], "window": ["type": "string"]] ] as [String: Any]],
        ["name": "tab_select", "description": "Focus a tab or surface by stable id or ref.", "inputSchema": ["type": "object", "properties": ["tab": ["type": "string"], "window": ["type": "string"], "workspace": ["type": "string"]], "required": ["tab"]] as [String: Any]],
        ["name": "surface_focus", "description": "Focus a surface by stable id or ref.", "inputSchema": ["type": "object", "properties": ["surface": ["type": "string"], "window": ["type": "string"], "workspace": ["type": "string"]], "required": ["surface"]] as [String: Any]],
        ["name": "surface_split", "description": "Split a surface in one direction.", "inputSchema": ["type": "object", "properties": ["direction": ["type": "string"], "surface": ["type": "string"], "command": ["type": "string"], "focus": ["type": "boolean"], "window": ["type": "string"], "workspace": ["type": "string"]], "required": ["direction"]] as [String: Any]],
        ["name": "palette_toggle", "description": "Toggle the command palette in the target window.", "inputSchema": ["type": "object", "properties": ["window": ["type": "string"]] as [String: Any]] as [String: Any]],
        ["name": "dialog_list", "description": "List pending agent permission, question and plan dialogs.", "inputSchema": ["type": "object", "properties": ["all": ["type": "boolean"]]] as [String: Any]],
        ["name": "dialog_answer", "description": "Answer one pending agent dialog.", "inputSchema": ["type": "object", "properties": ["request_id": ["type": "string"], "mode": ["type": "string"], "plan_mode": ["type": "string"], "selection": ["type": "string"], "selections": ["type": "array", "items": ["type": "string"]], "feedback": ["type": "string"]], "required": ["request_id"]] as [String: Any]],
    ]

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard let response = handle(line: line) else { continue }
            FileHandle.standardOutput.write(Data((response + "\n").utf8))
        }
    }

    private func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let protocolVersion = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
            return encode(["jsonrpc": "2.0", "id": id, "result": ["protocolVersion": protocolVersion, "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": "cmux-agent-surface", "version": self.version]]])
        case "ping":
            return encode(["jsonrpc": "2.0", "id": id, "result": [:]])
        case "tools/list":
            return encode(["jsonrpc": "2.0", "id": id, "result": ["tools": Self.tools]])
        case "tools/call":
            guard let name = params["name"] as? String else { return error(id: id, code: -32602, message: "tools/call needs a tool name") }
            guard Self.tools.contains(where: { $0["name"] as? String == name }) else { return error(id: id, code: -32602, message: "Unknown tool: \(name)") }
            do {
                let result = try callTool(name, params["arguments"] as? [String: Any] ?? [:])
                return encode(["jsonrpc": "2.0", "id": id, "result": ["content": result.content, "isError": result.isError]])
            } catch let error as CLIError {
                return encode(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": error.message]], "isError": true]])
            } catch {
                return encode(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": String(describing: error)]], "isError": true]])
            }
        default:
            return error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func error(id: Any, code: Int, message: String) -> String {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
