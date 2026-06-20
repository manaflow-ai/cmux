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

    private struct OpenChatWriteResult {
        var fileURL: URL
        var url: URL
        var title: String
        var allowedFiles: [DiffViewerAllowedFile]
    }

    private struct OpenChatContext {
        var workspaceName: String
        var repoName: String
        var repoRoot: String?
        var branchName: String?
        var branchLabel: String
    }

    private struct OpenChatLabels {
        var values: [String: String]

        var jsonObject: [String: Any] {
            values
        }

        static func localized() -> OpenChatLabels {
            OpenChatLabels(values: [
                "accountSwitcher": CMUXDiffViewerLocalization.string("openChat.accountSwitcher", defaultValue: "Account and model switcher"),
                "addCredits": CMUXDiffViewerLocalization.string("openChat.addCredits", defaultValue: "Add Credits"),
                "addCreditsUnavailable": CMUXDiffViewerLocalization.string("openChat.addCreditsUnavailable", defaultValue: "Credits are coming soon"),
                "approvalMode": CMUXDiffViewerLocalization.string("openChat.approvalMode", defaultValue: "Approval mode"),
                "approvalAutoReview": CMUXDiffViewerLocalization.string("openChat.approvalAutoReview", defaultValue: "Auto-review"),
                "approvalDefault": CMUXDiffViewerLocalization.string("openChat.approvalDefault", defaultValue: "Default"),
                "approvalFullAccess": CMUXDiffViewerLocalization.string("openChat.approvalFullAccess", defaultValue: "Full access"),
                "approvalReadOnly": CMUXDiffViewerLocalization.string("openChat.approvalReadOnly", defaultValue: "Read only"),
                "attachContext": CMUXDiffViewerLocalization.string("openChat.attachContext", defaultValue: "Attach context"),
                "branchSelector": CMUXDiffViewerLocalization.string("openChat.branchSelector", defaultValue: "Branch selector"),
                "connectApps": CMUXDiffViewerLocalization.string("openChat.connectApps", defaultValue: "Connect your favorite apps to Codex"),
                "connectAppsUnavailable": CMUXDiffViewerLocalization.string("openChat.connectAppsUnavailable", defaultValue: "App connections are coming soon"),
                "environmentSelector": CMUXDiffViewerLocalization.string("openChat.environmentSelector", defaultValue: "Environment selector"),
                "exampleSuggestion": CMUXDiffViewerLocalization.string("openChat.exampleSuggestion", defaultValue: "Plan and build a polished feature from this workspace"),
                "headingFormat": CMUXDiffViewerLocalization.string("openChat.headingFormat", defaultValue: "What should we build in %@?"),
                "model": CMUXDiffViewerLocalization.string("openChat.model", defaultValue: "Model"),
                "modelEffort": CMUXDiffViewerLocalization.string("openChat.modelEffort", defaultValue: "Model and reasoning"),
                "reasoning": CMUXDiffViewerLocalization.string("openChat.reasoning", defaultValue: "Reasoning"),
                "noBranch": CMUXDiffViewerLocalization.string("openChat.noBranch", defaultValue: "No branch"),
                "placeholder": CMUXDiffViewerLocalization.string("openChat.placeholder", defaultValue: "Ask Codex to build, fix, or explore..."),
                "rateLimitSubtitleFormat": CMUXDiffViewerLocalization.string("openChat.rateLimitSubtitleFormat", defaultValue: "Your rate limit resets on %@. Upgrade or use one of your rate limit resets now."),
                "rateLimitTitle": CMUXDiffViewerLocalization.string("openChat.rateLimitTitle", defaultValue: "You're out of Codex messages"),
                "reasoningExtraHigh": CMUXDiffViewerLocalization.string("openChat.reasoningExtraHigh", defaultValue: "Extra High"),
                "reasoningHigh": CMUXDiffViewerLocalization.string("openChat.reasoningHigh", defaultValue: "High"),
                "reasoningLow": CMUXDiffViewerLocalization.string("openChat.reasoningLow", defaultValue: "Low"),
                "reasoningMedium": CMUXDiffViewerLocalization.string("openChat.reasoningMedium", defaultValue: "Medium"),
                "repoSelector": CMUXDiffViewerLocalization.string("openChat.repoSelector", defaultValue: "Repository selector"),
                "resetUsage": CMUXDiffViewerLocalization.string("openChat.resetUsage", defaultValue: "Reset usage"),
                "resetUsageUnavailable": CMUXDiffViewerLocalization.string("openChat.resetUsageUnavailable", defaultValue: "Usage resets are coming soon"),
                "send": CMUXDiffViewerLocalization.string("openChat.send", defaultValue: "Send"),
                "submitUnavailableFormat": CMUXDiffViewerLocalization.string("openChat.submitUnavailableFormat", defaultValue: "Chat backend is coming soon. Draft kept here: %@"),
                "title": CMUXDiffViewerLocalization.string("openChat.title", defaultValue: "Open Chat"),
                "voiceInput": CMUXDiffViewerLocalization.string("openChat.voiceInput", defaultValue: "Voice input"),
                "voiceUnavailable": CMUXDiffViewerLocalization.string("openChat.voiceUnavailable", defaultValue: "Voice input is not available yet"),
                "workLocally": CMUXDiffViewerLocalization.string("openChat.workLocally", defaultValue: "Work locally"),
            ])
        }
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

    private func openChatContext(cwd: String, workspaceName: String?) -> OpenChatContext {
        let resolvedCWD = standardizedDiffSourcePath(cwd)
        let repoRoot = try? gitRepoRoot(startingAt: resolvedCWD)
        let repoLabelPath = repoRoot ?? resolvedCWD
        let repoName = openChatDisplayName(forPath: repoLabelPath)
        let workspaceLabel = normalizedDiffSourceValue(workspaceName) ?? repoName
        let branchName = repoRoot.flatMap(openChatCurrentBranch(in:))
        let branchLabel = branchName ?? OpenChatLabels.localized().values["noBranch"] ?? "No branch"
        return OpenChatContext(
            workspaceName: workspaceLabel,
            repoName: repoName,
            repoRoot: repoRoot,
            branchName: branchName,
            branchLabel: branchLabel
        )
    }

    private func openChatDisplayName(forPath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let lastPathComponent = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lastPathComponent.isEmpty {
            return lastPathComponent
        }
        return path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "cmux" : path
    }

    private func openChatCurrentBranch(in repoRoot: String) -> String? {
        if let branch = try? gitSingleLine(["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot),
           branch != "HEAD",
           !branch.isEmpty {
            return branch
        }
        return try? gitSingleLine(["rev-parse", "--short", "HEAD"], in: repoRoot)
    }

    private func writeOpenChat(
        context: OpenChatContext,
        appearance: DiffViewerAppearance,
        runtime: URL?
    ) throws -> OpenChatWriteResult {
        let directory = try diffViewerDirectory()
        let origin = try diffViewerHTTPServerOrigin(rootDirectory: directory, runtime: runtime)
        let mapper = DiffViewerURLMapper(
            token: UUID().uuidString.lowercased(),
            rootDirectory: directory,
            origin: origin,
            sessionHistoryMarker: DiffViewerURLMapper.openChatSessionHistoryMarker
        )
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "chat-\(timestamp)-\(UUID().uuidString.prefix(8)).html"
        let viewerFileURL = directory.appendingPathComponent(filename, isDirectory: false)
        let title = OpenChatLabels.localized().values["title"] ?? "Open Chat"
        try writeOpenChatHTML(
            to: viewerFileURL,
            title: title,
            context: context,
            appearance: appearance,
            runtime: runtime
        )
        let assets = try ensureDiffViewerAssets(nextTo: viewerFileURL, runtime: runtime)
        let allowedFiles = try diffViewerAllowedFiles(
            pageURLs: [viewerFileURL],
            assets: assets,
            mapper: mapper
        )
        try writeDiffViewerHTTPManifest(
            token: mapper.token,
            files: allowedFiles,
            rootDirectory: directory
        )
        return OpenChatWriteResult(
            fileURL: viewerFileURL,
            url: try mapper.viewerURL(for: viewerFileURL),
            title: title,
            allowedFiles: allowedFiles
        )
    }

    private func writeOpenChatHTML(
        to viewerURL: URL,
        title: String,
        context: OpenChatContext,
        appearance: DiffViewerAppearance,
        runtime: URL? = nil
    ) throws {
        let labels = OpenChatLabels.localized()
        var payload: [String: Any] = [
            "title": title,
            "workspaceName": context.workspaceName,
            "repoName": context.repoName,
            "branchName": context.branchLabel,
            "appearance": appearance.jsonObject,
            "labels": labels.jsonObject,
            "rateLimit": [
                "resetTime": openChatPlaceholderResetTime()
            ],
            "models": [
                ["id": "5.5", "label": "5.5", "selected": true],
                ["id": "5.1", "label": "5.1", "selected": false],
                ["id": "5", "label": "5", "selected": false],
            ],
            "reasoningLevels": [
                ["id": "extra-high", "label": labels.values["reasoningExtraHigh"] ?? "Extra High", "selected": true],
                ["id": "high", "label": labels.values["reasoningHigh"] ?? "High", "selected": false],
                ["id": "medium", "label": labels.values["reasoningMedium"] ?? "Medium", "selected": false],
                ["id": "low", "label": labels.values["reasoningLow"] ?? "Low", "selected": false],
            ],
            "approvalModes": [
                ["id": "full-access", "label": labels.values["approvalFullAccess"] ?? "Full access", "selected": true, "warning": true],
                ["id": "auto-review", "label": labels.values["approvalAutoReview"] ?? "Auto-review", "selected": false, "warning": false],
                ["id": "read-only", "label": labels.values["approvalReadOnly"] ?? "Read only", "selected": false, "warning": false],
                ["id": "default", "label": labels.values["approvalDefault"] ?? "Default", "selected": false, "warning": false],
            ],
            "contextOptions": [
                "repositories": [
                    ["id": context.repoName, "label": context.repoName, "selected": true],
                ],
                "environments": [
                    ["id": "local", "label": labels.values["workLocally"] ?? "Work locally", "selected": true],
                ],
                "branches": [
                    ["id": context.branchName ?? "no-branch", "label": context.branchLabel, "selected": true],
                ],
            ],
            "suggestions": [
                ["id": "example", "kind": "prompt", "label": labels.values["exampleSuggestion"] ?? "Plan and build a polished feature from this workspace"],
                ["id": "apps", "kind": "apps", "label": labels.values["connectApps"] ?? "Connect your favorite apps to Codex"],
            ],
            "generatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let repoRoot = context.repoRoot {
            payload["repoRoot"] = repoRoot
        }
        let assets = try ensureDiffViewerAssets(nextTo: viewerURL, runtime: runtime)
        let config: [String: Any] = [
            "payload": payload,
            "assets": [
                "diffsModuleURL": assets.diffsModuleURL,
                "treesModuleURL": assets.treesModuleURL,
                "workerPoolModuleURL": assets.workerPoolModuleURL,
                "workerModuleURL": assets.workerModuleURL
            ]
        ]
        let configLiteral = try jsonScriptLiteral(config)
        let appModuleURL = htmlEscaped(assets.appModuleURL)
        let escapedTitle = htmlEscaped(title)
        let htmlLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        let prepaintStyle = diffViewerPrepaintStyle(appearance: appearance)
        let html = """
        <!doctype html>
        <html lang="\(htmlEscaped(htmlLanguage))" data-cmux-webview-kind="open-chat">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapedTitle)</title>
          \(prepaintStyle)
        </head>
        <body data-cmux-webview-kind="open-chat">
          <script id="cmux-open-chat-config" type="application/json">\(configLiteral)</script>
          <div id="root"></div>
          <script type="module" src="\(appModuleURL)"></script>
        </body>
        </html>
        """
        try html.write(to: viewerURL, atomically: true, encoding: .utf8)
    }

    private func openChatPlaceholderResetTime() -> String {
        let resetDate = Date().addingTimeInterval(2 * 60 * 60)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.locale = Locale.current
        return formatter.string(from: resetDate)
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
