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
                throw CLIError(message: "--focus must be true|false")
            }
            focus = parsed
        } else {
            focus = false
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
        let context = openChatContext(cwd: cwd, workspaceName: parsedArgs.workspaceName)
        let appearance = diffViewerAppearance(socketPath: socketPath, fontSizeOverride: nil)
        let runtime = diffViewerRuntime(socketPath: socketPath)
        let viewer = try writeOpenChat(
            context: context,
            appearance: appearance,
            runtime: runtime
        )

        try resolveTargetIfNeeded()
        let activeClient = try connectedClient()

        var params: [String: Any] = [
            "url": viewer.url.absoluteString,
            "focus": focus,
            "show_omnibar": false,
            "transparent_background": true,
            "bypass_remote_proxy": true
        ]
        if viewer.url.scheme == DiffViewerURLMapper.scheme {
            params["diff_viewer_token"] = viewer.url.host ?? ""
            params["diff_viewer_files"] = viewer.allowedFiles.map(\.jsonObject)
        }
        if let windowHandle { params["window_id"] = windowHandle }
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let surfaceHandle { params["surface_id"] = surfaceHandle }

        let payload = try activeClient.sendV2(method: "browser.open_split", params: params)

        if jsonOutput {
            var response = payload
            response["path"] = viewer.fileURL.path
            response["url"] = viewer.url.absoluteString
            response["title"] = viewer.title
            response["repo"] = context.repoName
            response["branch"] = context.branchName ?? NSNull()
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

        Open the Codex-style Chat composer in a cmux browser split.

        Options:
          --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
          --surface <id|ref|index>     Source surface to split from (default: $CMUX_SURFACE_ID)
          --window <id|ref|index>      Target window
          --cwd, --repo <path>         Repository or workspace path used for Chat context
          --workspace-name <name>      Workspace name shown in the Chat heading
          --focus <true|false>         Focus the Chat browser split (default: false)
          --no-focus                   Do not focus the opened Chat browser split

        Examples:
          cmux open-chat
          cmux chat --cwd ~/src/app --focus true
        """
        )
    }

    private func openChatUnknownFlagMessage(_ flag: String) -> String {
        let format = CMUXDiffViewerLocalization.string(
            "cli.openChat.error.unknownFlagFormat",
            defaultValue: "open-chat: unknown flag '%@'. Usage: cmux open-chat [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--cwd <path>] [--workspace-name <name>] [--focus true|false] [--no-focus]"
        )
        return String(format: format, flag)
    }

    private func openChatNoPositionalsMessage() -> String {
        CMUXDiffViewerLocalization.string(
            "cli.openChat.error.noPositionals",
            defaultValue: "open-chat does not accept positional arguments. Usage: cmux open-chat [options]"
        )
    }
}
