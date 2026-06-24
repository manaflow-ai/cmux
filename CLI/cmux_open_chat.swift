import Foundation

extension CMUXCLI {
    private struct OpenChatArguments {
        var workspace: String?
        var window: String?
        var surface: String?
        var focus: String?
        var noFocus = false
        var cwd: String?
        var workspaceName: String?
        var provider: String?
        var renderer: String?
        var model: String?
        var openCodeProvider: String?
    }

    func runOpenChatCommand(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let parsedArgs = try parseOpenChatArguments(commandArgs)
        let focus: Bool
        if parsedArgs.noFocus {
            focus = false
        } else if let focusOpt = parsedArgs.focus {
            guard let parsed = parseBoolString(focusOpt) else {
                throw CLIError(message: openChatInvalidFocusMessage())
            }
            focus = parsed
        } else {
            focus = true
        }

        var client: SocketClient?
        var didResolveTarget = false
        var windowHandle: String?
        var workspaceHandle: String?
        var surfaceHandle: String?
        defer { client?.close() }

        func connectedClient() throws -> SocketClient {
            if let client {
                return client
            }
            let newClient = try connectClient(
                socketPath: socketPath,
                explicitPassword: explicitPassword,
                launchIfNeeded: true
            )
            client = newClient
            return newClient
        }

        func resolveTargetIfNeeded() throws {
            guard !didResolveTarget else { return }
            let activeClient = try connectedClient()
            windowHandle = try normalizeWindowHandle(parsedArgs.window, client: activeClient)
            let workspaceRaw = parsedArgs.workspace ?? (parsedArgs.window == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: activeClient, windowHandle: windowHandle)
            let surfaceRaw = parsedArgs.surface ?? (parsedArgs.window == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: activeClient, workspaceHandle: workspaceHandle, windowHandle: windowHandle)
            didResolveTarget = true
        }

        let cwd = parsedArgs.cwd.map(resolvePath) ?? FileManager.default.currentDirectoryPath
        try resolveTargetIfNeeded()
        let activeClient = try connectedClient()

        var params: [String: Any] = [
            "type": "agent-session",
            "direction": "right",
            "provider_id": parsedArgs.provider ?? "codex",
            "renderer_kind": parsedArgs.renderer ?? "react",
            "working_directory": cwd,
            "focus": focus,
        ]
        if let model = parsedArgs.model { params["model_id"] = model }
        if let openCodeProvider = parsedArgs.openCodeProvider { params["opencode_provider_id"] = openCodeProvider }
        if let windowHandle { params["window_id"] = windowHandle }
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let surfaceHandle { params["surface_id"] = surfaceHandle }

        let payload = try activeClient.sendV2(method: "pane.create", params: params)

        if jsonOutput {
            var response = payload
            response["provider"] = parsedArgs.provider ?? "codex"
            response["renderer"] = parsedArgs.renderer ?? "react"
            if let model = parsedArgs.model { response["model"] = model }
            if let openCodeProvider = parsedArgs.openCodeProvider { response["opencode_provider"] = openCodeProvider }
            print(jsonString(formatIDs(response, mode: idFormat)))
            return
        }

        let surfaceText = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown"
        let paneText = formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown"
        print("OK surface=\(surfaceText) pane=\(paneText)")
    }

    private func parseOpenChatArguments(_ commandArgs: [String]) throws -> OpenChatArguments {
        var parsed = OpenChatArguments()
        var index = 0
        var isParsingOptions = true

        while index < commandArgs.count {
            let arg = commandArgs[index]
            if isParsingOptions, arg == "--" {
                isParsingOptions = false
                index += 1
                continue
            }

            if isParsingOptions {
                switch arg {
                case "--workspace":
                    parsed.workspace = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--window":
                    parsed.window = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--surface":
                    parsed.surface = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--focus":
                    parsed.focus = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--no-focus":
                    parsed.noFocus = true
                    index += 1
                    continue
                case "--cwd", "--repo", "--path":
                    parsed.cwd = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--workspace-name":
                    parsed.workspaceName = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--provider", "--provider-id":
                    parsed.provider = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--renderer", "--renderer-kind":
                    parsed.renderer = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--model", "--model-id":
                    parsed.model = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--opencode-provider", "--open-code-provider":
                    parsed.openCodeProvider = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                default:
                    if arg.hasPrefix("-") {
                        throw CLIError(message: openChatUnknownFlagMessage(arg))
                    }
                    throw CLIError(message: openChatNoPositionalsMessage())
                }
            } else if !arg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CLIError(message: openChatNoPositionalsMessage())
            }

            index += 1
        }

        return parsed
    }

    func openChatSubcommandUsage() -> String {
        CMUXDiffViewerLocalization.string(
            "cli.openChat.usage",
            defaultValue: """
        Usage: cmux open-chat [options]
               cmux chat [options]

        Open an AI agent Chat pane in cmux.

        Options:
          --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
          --surface <id|ref|index>     Source surface to split from (default: $CMUX_SURFACE_ID)
          --window <id|ref|index>      Target window
          --cwd, --repo, --path <path> Repository or workspace path used for Chat context
          --workspace-name <name>      Accepted for compatibility
          --provider <provider>        Agent backend: codex, claude, or opencode (default: codex)
          --model <model>              Backend model id, or provider/model for OpenCode
          --opencode-provider <id>     OpenCode provider id when --model omits provider/
          --renderer <renderer>        Agent renderer: react or solid (default: react)
          --focus <true|false>         Focus the Chat pane (default: true)
          --no-focus                   Do not focus the opened Chat pane

        Examples:
          cmux open-chat
          cmux chat --cwd ~/src/app --focus true
        """
        )
    }

    private func openChatUnknownFlagMessage(_ flag: String) -> String {
        let format = CMUXDiffViewerLocalization.string(
            "cli.openChat.error.unknownFlagFormat",
            defaultValue: "open-chat: unknown flag '%@'. Usage: cmux open-chat [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--cwd|--repo|--path <path>] [--workspace-name <name>] [--provider <codex|claude|opencode>] [--model <model|provider/model>] [--opencode-provider <id>] [--renderer <react|solid>] [--focus true|false] [--no-focus]"
        )
        return String(format: format, flag)
    }

    private func openChatInvalidFocusMessage() -> String {
        CMUXDiffViewerLocalization.string(
            "cli.openChat.error.invalidFocus",
            defaultValue: "--focus must be true|false"
        )
    }

    private func openChatNoPositionalsMessage() -> String {
        CMUXDiffViewerLocalization.string(
            "cli.openChat.error.noPositionals",
            defaultValue: "open-chat does not accept positional arguments. Usage: cmux open-chat [options]"
        )
    }
}
