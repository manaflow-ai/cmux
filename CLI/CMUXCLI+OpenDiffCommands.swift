import Darwin
import Foundation


// MARK: - Open & Diff Command Entry Points and Argument Parsing
extension CMUXCLI {
    func runOpenCommand(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let parsedArgs = try parseOpenArguments(commandArgs)

        guard !parsedArgs.targets.isEmpty else {
            throw CLIError(message: "open requires at least one path or URL. Usage: cmux open <path-or-url>...")
        }

        let focus: Bool
        if parsedArgs.noFocus {
            focus = false
        } else if let focusOpt = parsedArgs.focus {
            guard let parsed = parseBoolString(focusOpt) else {
                throw CLIError(message: "--focus must be true|false")
            }
            focus = parsed
        } else {
            focus = true
        }

        let targets = try parsedArgs.targets.map(resolveOpenTarget)
        var fileCount = 0
        var urlCount = 0
        var directoryCount = 0

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        let windowHandle = try normalizeWindowHandle(parsedArgs.window, client: client)
        let workspaceRaw = parsedArgs.workspace ?? (parsedArgs.window == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle)
        let surfaceRaw = parsedArgs.surface ?? (parsedArgs.window == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle, windowHandle: windowHandle)
        let paneHandle = try normalizePaneHandle(parsedArgs.pane, client: client, workspaceHandle: workspaceHandle)

        var payloads: [[String: Any]] = []

        var pendingFiles: [String] = []
        func flushPendingFiles() throws {
            guard !pendingFiles.isEmpty else { return }
            let files = pendingFiles
            pendingFiles.removeAll()

            var params: [String: Any] = ["paths": files, "focus": focus]
            if let windowHandle { params["window_id"] = windowHandle }
            if let workspaceHandle { params["workspace_id"] = workspaceHandle }
            if let surfaceHandle { params["surface_id"] = surfaceHandle }
            if let paneHandle { params["pane_id"] = paneHandle }
            let payload = try client.sendV2(method: "file.open", params: params)
            payloads.append(["kind": "file", "payload": payload])
            fileCount += files.count
        }

        for target in targets {
            switch target {
            case .file(let path):
                pendingFiles.append(path)
            case .directory(let directory):
                try flushPendingFiles()
                var params: [String: Any] = ["cwd": directory]
                if let windowHandle { params["window_id"] = windowHandle }
                let payload = try client.sendV2(method: "workspace.create", params: params)
                payloads.append(["kind": "workspace", "payload": payload, "path": directory])
                directoryCount += 1
            case .url(let url):
                try flushPendingFiles()
                var params: [String: Any] = ["url": url, "focus": focus]
                if let windowHandle { params["window_id"] = windowHandle }
                if let workspaceHandle { params["workspace_id"] = workspaceHandle }
                if let surfaceHandle { params["surface_id"] = surfaceHandle }
                let payload = try client.sendV2(method: "browser.open_split", params: params)
                payloads.append(["kind": "url", "payload": payload, "url": url])
                urlCount += 1
            }
        }
        try flushPendingFiles()

        if jsonOutput {
            print(jsonString(formatIDs(["opened": payloads], mode: idFormat)))
            return
        }

        print(openCommandSummary(
            payloads: payloads,
            fileCount: fileCount,
            urlCount: urlCount,
            directoryCount: directoryCount,
            idFormat: idFormat
        ))
    }

    func runDiffCommand(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let parsedArgs = try parseDiffArguments(commandArgs)
        guard parsedArgs.inputs.count <= 1 else {
            throw CLIError(message: "diff accepts at most one patch file. Usage: cmux diff [patch-file|-] [options]")
        }
        if parsedArgs.source != nil, !parsedArgs.inputs.isEmpty {
            throw CLIError(message: "diff accepts either a patch file or a git source, not both")
        }

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

        let resolvedLayout = try resolveDiffViewerLayout(rawLayout: parsedArgs.layout)
        let layout = resolvedLayout.layout
        let layoutSource = resolvedLayout.source

        let fontSizeOverride: Double?
        if let rawFontSize = parsedArgs.fontSize {
            fontSizeOverride = try parseDiffViewerFontSize(rawFontSize)
        } else {
            fontSizeOverride = nil
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

        var diffSourceContext = DiffSourceContext(
            workspaceId: nil,
            surfaceId: nil,
            repoRoot: nil,
            branchBaseRef: parsedArgs.branchBase
        )
        if let cwd = parsedArgs.cwd {
            diffSourceContext.repoRoot = try gitRepoRoot(startingAt: resolvePath(cwd))
        }
        if parsedArgs.source != nil {
            try resolveTargetIfNeeded()
            var sourceContext = try canonicalDiffSourceContext(
                workspaceHandle: workspaceHandle,
                surfaceHandle: surfaceHandle,
                windowHandle: windowHandle,
                client: try connectedClient()
            )
            sourceContext.repoRoot = diffSourceContext.repoRoot
            sourceContext.branchBaseRef = diffSourceContext.branchBaseRef
            diffSourceContext = sourceContext
            workspaceHandle = sourceContext.workspaceId ?? workspaceHandle
            surfaceHandle = sourceContext.surfaceId ?? surfaceHandle
        }

        let appearance = diffViewerAppearance(
            socketPath: socketPath,
            fontSizeOverride: fontSizeOverride
        )
        let runtime = diffViewerRuntime(socketPath: socketPath)
        let viewer = try writeDiffViewer(
            rawInput: parsedArgs.inputs.first,
            source: parsedArgs.source,
            titleOverride: parsedArgs.title,
            layout: layout,
            layoutSource: layoutSource,
            appearance: appearance,
            context: diffSourceContext,
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
            let completedViewer = try completeDeferredDiffViewer(viewer)
            var response = payload
            response["path"] = completedViewer.fileURL.path
            response["url"] = completedViewer.url.absoluteString
            response["title"] = completedViewer.title
            response["source"] = completedViewer.input.sourceLabel
            print(jsonString(formatIDs(response, mode: idFormat)))
            return
        }

        // Finalize the deferred viewer (writes the real diff HTML in place of the
        // opening placeholder); its temp file path is an internal detail, so keep it
        // out of the human output. Scripts that need it can use `--json`.
        _ = try completeDeferredDiffViewer(viewer)
        let surfaceText = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown"
        let paneText = formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown"
        print("OK surface=\(surfaceText) pane=\(paneText)")
    }

    private func diffViewerRuntime(socketPath: String) -> URL? {
        if let taggedExecutableURL = taggedDiffViewerExecutableURL(socketPath: socketPath) {
            return taggedExecutableURL
        }
        return nil
    }

    func diffViewerExecutableURL(for runtime: URL?) -> URL? {
        runtime ?? resolvedExecutableURL()
    }

    private func taggedDiffViewerExecutableURL(socketPath: String) -> URL? {
        let socketName = URL(fileURLWithPath: socketPath).lastPathComponent
        let prefix = "cmux-debug-"
        let suffix = ".sock"
        guard socketName.hasPrefix(prefix), socketName.hasSuffix(suffix) else {
            return nil
        }

        let tagStart = socketName.index(socketName.startIndex, offsetBy: prefix.count)
        let tagEnd = socketName.index(socketName.endIndex, offsetBy: -suffix.count)
        let tag = String(socketName[tagStart..<tagEnd])
        guard !tag.isEmpty,
              tag.allSatisfy({ character in
                  character.isLetter || character.isNumber || character == "-" || character == "_"
              }) else {
            return nil
        }

        let homePath = ProcessInfo.processInfo.environment["HOME"]
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? NSHomeDirectory()
        let candidate = URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("Library/Developer/Xcode/DerivedData/cmux-\(tag)", isDirectory: true)
            .appendingPathComponent("Build/Products/Debug/cmux DEV \(tag).app", isDirectory: true)
            .appendingPathComponent("Contents/Resources/bin/cmux", isDirectory: false)
            .standardizedFileURL

        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            return nil
        }
        return canonicalFileURL(candidate)
    }

    private func parseOpenArguments(_ commandArgs: [String]) throws -> OpenArguments {
        var parsed = OpenArguments()
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
                case "--pane":
                    parsed.pane = try openOptionValue(commandArgs, index: index, name: arg)
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
                default:
                    if arg.hasPrefix("-") {
                        throw CLIError(message: "open: unknown flag '\(arg)'. Usage: cmux open <path-or-url>... [--workspace <id|ref|index>] [--surface <id|ref|index>] [--pane <id|ref|index>] [--window <id|ref|index>] [--focus true|false] [--no-focus]")
                    }
                }
            }

            parsed.targets.append(arg)
            index += 1
        }

        return parsed
    }

    private func parseDiffArguments(_ commandArgs: [String]) throws -> DiffArguments {
        var parsed = DiffArguments()
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
                case "--title":
                    parsed.title = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--layout":
                    parsed.layout = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--font-size":
                    parsed.fontSize = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--cwd", "--repo", "--path":
                    parsed.cwd = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--base", "--branch-base":
                    parsed.branchBase = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--source":
                    let rawSource = try openOptionValue(commandArgs, index: index, name: arg)
                    guard let source = DiffSource(rawValue: rawSource) else {
                        throw CLIError(message: "Unknown diff source '\(rawSource)'. Expected unstaged, staged, branch, or last-turn.")
                    }
                    try setDiffSource(source, parsed: &parsed)
                    index += 2
                    continue
                case "--unstaged":
                    try setDiffSource(.unstaged, parsed: &parsed)
                    index += 1
                    continue
                case "--staged":
                    try setDiffSource(.staged, parsed: &parsed)
                    index += 1
                    continue
                case "--branch":
                    try setDiffSource(.branch, parsed: &parsed)
                    index += 1
                    continue
                case "--last-turn":
                    try setDiffSource(.lastTurn, parsed: &parsed)
                    index += 1
                    continue
                default:
                    if arg.hasPrefix("-"), arg != "-" {
                        throw CLIError(message: "diff: unknown flag '\(arg)'. Usage: cmux diff [patch-file|-] [--source <unstaged|staged|branch|last-turn>] [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--cwd <path>] [--base <ref>] [--focus true|false] [--no-focus] [--title <text>] [--layout split|unified] [--font-size <points>]")
                    }
                }
            }

            parsed.inputs.append(arg)
            index += 1
        }

        return parsed
    }

    private func setDiffSource(_ source: DiffSource, parsed: inout DiffArguments) throws {
        if let existing = parsed.source, existing != source {
            throw CLIError(message: "diff accepts only one source, got \(existing.optionName) and \(source.optionName)")
        }
        parsed.source = source
    }

    private func openOptionValue(_ args: [String], index: Int, name: String) throws -> String {
        guard index + 1 < args.count else {
            throw CLIError(message: "\(name) requires a value")
        }
        return args[index + 1]
    }

    private func parseDiffViewerFontSize(_ rawValue: String) throws -> Double {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Double(trimmed),
              isUsableDiffViewerFontSize(size) else {
            throw CLIError(message: "--font-size must be a positive number no larger than 96")
        }
        return roundedDiffViewerMetric(size)
    }

    private func resolveDiffViewerLayout(rawLayout: String?) throws -> (layout: String, source: String) {
        if let rawLayout {
            return (try parseDiffViewerLayout(rawLayout, errorMessage: "--layout must be split|unified"), "explicit")
        }
        return (diffViewerDefaultLayoutSetting() ?? "unified", "default")
    }

    private func parseDiffViewerLayout(_ rawValue: String, errorMessage: String) throws -> String {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized == "split" || normalized == "unified" else {
            throw CLIError(message: errorMessage)
        }
        return normalized
    }

    private func diffViewerDefaultLayoutSetting() -> String? {
        for path in diffViewerDefaultSettingsPaths() {
            guard let root = diffViewerSettingsRoot(at: path),
                  let section = root["diffViewer"] as? [String: Any],
                  let rawLayout = section["defaultLayout"] as? String,
                  let layout = try? parseDiffViewerLayout(
                      rawLayout,
                      errorMessage: "diffViewer.defaultLayout must be split|unified"
                  ) else {
                continue
            }
            return layout
        }
        return nil
    }

    private func diffViewerDefaultSettingsPaths() -> [String] {
        [
            Self.primarySettingsDisplayPath,
            Self.legacySettingsDisplayPath,
            Self.fallbackSettingsDisplayPath,
        ].map(Self.absoluteDiffViewerSettingsPath)
    }

    private func diffViewerSettingsRoot(at path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !data.isEmpty,
              let sanitized = try? JSONCParser.preprocess(data: data),
              let root = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any] else {
            return nil
        }
        return root
    }

    private func resolveOpenTarget(_ raw: String) throws -> OpenTarget {
        if let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return .url(url.absoluteString)
        }

        let resolved = resolvePath(raw)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
            throw CLIError(message: "Path does not exist: \(resolved)")
        }

        if isDir.boolValue {
            return .directory(resolved)
        }
        return .file(resolved)
    }

    func openSubcommandUsage() -> String {
        """
        Usage: cmux open <path-or-url>... [options]

        Open files, directories, or URLs in cmux.
        Markdown files open in markdown preview tabs; other files open in file preview tabs.
        Multiple files open as tabs in the same target pane.

        Options:
          --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
          --surface <id|ref|index>     Target surface whose pane should receive file tabs (default: $CMUX_SURFACE_ID)
          --pane <id|ref|index>        Target pane for file tabs
          --window <id|ref|index>      Target window
          --focus <true|false>         Focus opened file previews (default: true)
          --no-focus                   Do not focus opened file previews

        Examples:
          cmux open report.pdf
          cmux open image-a.png image-b.jpg
          cmux open ~/Downloads/movie.mov --pane pane:1
          cmux open https://example.com
        """
    }

    func diffSubcommandUsage() -> String {
        """
        Usage: cmux diff [patch-file|-] [options]

        Render a unified diff or patch in a cmux browser split.
        With no patch file or source, cmux diff reads piped stdin.

        Options:
          --source <name>              Diff source: unstaged, staged, branch, last-turn
          --unstaged                   Show unstaged git changes
          --staged                     Show staged git changes
          --branch                     Show current branch against merge base
          --last-turn                  Show changes since this surface's last agent-turn baseline
          --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
          --surface <id|ref|index>     Source surface to split from (default: $CMUX_SURFACE_ID)
          --window <id|ref|index>      Target window
          --cwd, --repo <path>          Git repository or worktree path for git sources
          --base <ref>                  Base ref for --branch (default: origin/HEAD or main)
          --focus <true|false>         Focus the diff browser split (default: false)
          --no-focus                   Do not focus the opened diff browser split
          --title <text>               Set the diff viewer title to the provided text
          --layout <split|unified>     Diff layout (default: unified; configurable via diffViewer.defaultLayout in cmux.json)
          --font-size <points>         Set diff font size (default: 10)

        Examples:
          cmux diff changes.patch
          git diff | cmux diff
          cmux diff --unstaged
          cmux diff --staged
          cmux diff --branch
          cmux diff --branch --base upstream/main --repo ../repo
          cmux diff --last-turn
          cmux diff pr.patch --layout unified --font-size 15 --focus true
        """
    }

    private func openCommandSummary(
        payloads: [[String: Any]],
        fileCount: Int,
        urlCount: Int,
        directoryCount: Int,
        idFormat: CLIIDFormat
    ) -> String {
        let filePayload = payloads.first { ($0["kind"] as? String) == "file" }?["payload"] as? [String: Any]
        let surfaceText = filePayload.flatMap { formatHandle($0, kind: "surface", idFormat: idFormat) }
        let paneText = filePayload.flatMap { formatHandle($0, kind: "pane", idFormat: idFormat) }
        var pieces = ["OK"]
        if fileCount > 0 {
            pieces.append("files=\(fileCount)")
            if let surfaceText { pieces.append("surface=\(surfaceText)") }
            if let paneText { pieces.append("pane=\(paneText)") }
        }
        if urlCount > 0 {
            pieces.append("urls=\(urlCount)")
        }
        if directoryCount > 0 {
            pieces.append("workspaces=\(directoryCount)")
        }
        return pieces.joined(separator: " ")
    }
}
