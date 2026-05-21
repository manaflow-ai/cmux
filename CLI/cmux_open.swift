import Darwin
import Foundation

struct CMUXAgentTurnDiffBaselineRecord: Codable {
    var workspaceId: String
    var surfaceId: String
    var sessionId: String
    var turnId: String?
    var agent: String
    var repoRoot: String
    var baseCommit: String
    var capturedAt: TimeInterval
}

struct CMUXAgentTurnDiffBaselineStore: Codable {
    var version: Int = 1
    var records: [CMUXAgentTurnDiffBaselineRecord] = []
}

enum CMUXAgentTurnDiffBaselineFile {
    static func path(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let overrideDirectory = normalized(env["CMUX_AGENT_HOOK_STATE_DIR"]) {
            return URL(fileURLWithPath: NSString(string: overrideDirectory).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("agent-turn-diff-baselines.json", isDirectory: false)
                .path
        }
        return NSString(string: "~/.cmuxterm/agent-turn-diff-baselines.json").expandingTildeInPath
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

extension CMUXCLI {
    private struct OpenArguments {
        var workspace: String?
        var window: String?
        var surface: String?
        var pane: String?
        var focus: String?
        var noFocus = false
        var targets: [String] = []
    }

    private enum OpenTarget {
        case directory(String)
        case file(String)
        case url(String)
    }

    private struct DiffArguments {
        var workspace: String?
        var window: String?
        var surface: String?
        var focus: String?
        var noFocus = false
        var title: String?
        var layout: String?
        var fontSize: String?
        var source: DiffSource?
        var inputs: [String] = []
    }

    private struct DiffInput {
        var patch: String
        var sourceLabel: String
        var defaultTitle: String
        var emptyMessage: String?
    }

    private struct DiffSourceContext {
        var workspaceId: String?
        var surfaceId: String?
    }

    private enum DiffSource: Equatable {
        case unstaged
        case staged
        case branch
        case lastTurn

        init?(rawValue: String) {
            let normalized = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
                .replacingOccurrences(of: " ", with: "-")
            switch normalized {
            case "unstaged", "worktree", "working-tree", "workingtree":
                self = .unstaged
            case "staged", "cached", "index":
                self = .staged
            case "branch":
                self = .branch
            case "last", "last-turn", "lastturn":
                self = .lastTurn
            default:
                return nil
            }
        }

        var optionName: String {
            switch self {
            case .unstaged: return "--unstaged"
            case .staged: return "--staged"
            case .branch: return "--branch"
            case .lastTurn: return "--last-turn"
            }
        }

        var title: String {
            switch self {
            case .unstaged: return "Unstaged changes"
            case .staged: return "Staged changes"
            case .branch: return "Branch diff"
            case .lastTurn: return "Last turn diff"
            }
        }

        var emptyMessage: String {
            switch self {
            case .unstaged: return "No unstaged changes to diff."
            case .staged: return "No staged changes to diff."
            case .branch: return "No branch changes to diff."
            case .lastTurn: return "No last-turn changes to diff."
            }
        }
    }

    private enum DiffViewerColorScheme {
        case light
        case dark
    }

    private struct DiffViewerAppearance {
        var fontFamily: String
        var fontSize: Double
        var lightTheme: DiffViewerTheme
        var darkTheme: DiffViewerTheme

        var lineHeight: Double {
            let scaled = max(fontSize + 4, fontSize * 20.0 / 13.0)
            return (scaled * 100).rounded() / 100
        }

        var diffHeaderHeight: Double {
            ((lineHeight + 24) * 100).rounded() / 100
        }

        var jsonObject: [String: Any] {
            [
                "fontFamily": fontFamily,
                "fontSize": fontSize,
                "lineHeight": lineHeight,
                "diffHeaderHeight": diffHeaderHeight,
                "theme": [
                    "light": lightTheme.generatedName,
                    "dark": darkTheme.generatedName
                ],
                "themes": [
                    "light": lightTheme.jsonObject,
                    "dark": darkTheme.jsonObject
                ]
            ]
        }
    }

    private struct DiffViewerTheme {
        var generatedName: String
        var ghosttyName: String
        var type: String
        var background: String
        var foreground: String
        var selectionBackground: String
        var selectionForeground: String
        var palette: [Int: String]

        var jsonObject: [String: Any] {
            [
                "name": generatedName,
                "ghosttyName": ghosttyName,
                "type": type,
                "background": background,
                "foreground": foreground,
                "selectionBackground": selectionBackground,
                "selectionForeground": selectionForeground,
                "palette": Dictionary(uniqueKeysWithValues: palette.map { (String($0.key), $0.value) })
            ]
        }
    }

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
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle)
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

        let layout = parsedArgs.layout ?? "split"
        guard layout == "split" || layout == "unified" else {
            throw CLIError(message: "--layout must be split|unified")
        }

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
            surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: activeClient, workspaceHandle: workspaceHandle)
            didResolveTarget = true
        }

        if parsedArgs.source == .lastTurn {
            try resolveTargetIfNeeded()
        }

        let input = try readDiffInput(
            parsedArgs.inputs.first,
            source: parsedArgs.source,
            context: DiffSourceContext(workspaceId: workspaceHandle, surfaceId: surfaceHandle)
        )
        let trimmedPatch = input.patch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPatch.isEmpty else {
            throw CLIError(message: input.emptyMessage ?? "diff input is empty")
        }

        let title = parsedArgs.title ?? input.defaultTitle
        let viewerURL = try writeDiffViewerHTML(
            patch: input.patch,
            title: title,
            sourceLabel: input.sourceLabel,
            layout: layout,
            appearance: diffViewerAppearance(fontSizeOverride: fontSizeOverride)
        )

        try resolveTargetIfNeeded()
        let activeClient = try connectedClient()

        var params: [String: Any] = [
            "url": viewerURL.absoluteString,
            "focus": focus
        ]
        if let windowHandle { params["window_id"] = windowHandle }
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let surfaceHandle { params["surface_id"] = surfaceHandle }

        let payload = try activeClient.sendV2(method: "browser.open_split", params: params)

        if jsonOutput {
            var response = payload
            response["path"] = viewerURL.path
            response["url"] = viewerURL.absoluteString
            response["title"] = title
            response["source"] = input.sourceLabel
            print(jsonString(formatIDs(response, mode: idFormat)))
            return
        }

        let surfaceText = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown"
        let paneText = formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown"
        print("OK surface=\(surfaceText) pane=\(paneText) path=\(viewerURL.path)")
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
                    parsed.workspace = try diffOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--window":
                    parsed.window = try diffOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--surface":
                    parsed.surface = try diffOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--focus":
                    parsed.focus = try diffOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--no-focus":
                    parsed.noFocus = true
                    index += 1
                    continue
                case "--title":
                    parsed.title = try diffOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--layout":
                    parsed.layout = try diffOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--font-size":
                    parsed.fontSize = try diffOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--source":
                    let rawSource = try diffOptionValue(commandArgs, index: index, name: arg)
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
                        throw CLIError(message: "diff: unknown flag '\(arg)'. Usage: cmux diff [patch-file|-] [--source <unstaged|staged|branch|last-turn>] [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--focus true|false] [--no-focus] [--title <text>] [--layout split|unified] [--font-size <points>]")
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

    private func diffOptionValue(_ args: [String], index: Int, name: String) throws -> String {
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

    private func readDiffInput(
        _ rawInput: String?,
        source: DiffSource?,
        context: DiffSourceContext
    ) throws -> DiffInput {
        if let source {
            return try readGitDiffInput(source: source, context: context)
        }

        guard let rawInput, rawInput != "-" else {
            guard isatty(STDIN_FILENO) == 0 else {
                throw CLIError(message: "diff requires a patch file, piped stdin, or a git source. Usage: cmux diff <patch-file>|-|--unstaged|--staged|--branch|--last-turn")
            }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return DiffInput(
                patch: try decodeDiffData(data, sourceDescription: "stdin"),
                sourceLabel: "stdin",
                defaultTitle: "cmux diff",
                emptyMessage: nil
            )
        }

        let resolved = resolvePath(rawInput)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
            throw CLIError(message: "Path does not exist: \(resolved)")
        }
        guard !isDir.boolValue else {
            throw CLIError(message: "Path is a directory, not a patch file: \(resolved)")
        }
        guard FileManager.default.isReadableFile(atPath: resolved) else {
            throw CLIError(message: "File not readable: \(resolved)")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: resolved))
        let filename = URL(fileURLWithPath: resolved).lastPathComponent
        return DiffInput(
            patch: try decodeDiffData(data, sourceDescription: resolved),
            sourceLabel: resolved,
            defaultTitle: filename.isEmpty ? "cmux diff" : filename,
            emptyMessage: nil
        )
    }

    private func readGitDiffInput(source: DiffSource, context: DiffSourceContext) throws -> DiffInput {
        let repoRoot = try currentGitRepoRoot()
        let patch: String
        let sourceLabel: String
        switch source {
        case .unstaged:
            patch = try gitStdout(["diff", "--no-ext-diff", "--binary", "--"], in: repoRoot)
            sourceLabel = "git unstaged"
        case .staged:
            patch = try gitStdout(["diff", "--no-ext-diff", "--binary", "--cached", "--"], in: repoRoot)
            sourceLabel = "git staged"
        case .branch:
            let baseRef = try gitBranchDiffBaseRef(in: repoRoot)
            let mergeBase = try gitSingleLine(["merge-base", "HEAD", baseRef], in: repoRoot)
            patch = try gitStdout(["diff", "--no-ext-diff", "--binary", mergeBase, "--"], in: repoRoot)
            sourceLabel = "git branch \(baseRef)"
        case .lastTurn:
            guard let workspaceId = normalizedDiffSourceValue(context.workspaceId),
                  let surfaceId = normalizedDiffSourceValue(context.surfaceId) else {
                throw CLIError(message: "cmux diff --last-turn requires a workspace and surface context. Run it from a cmux terminal or pass --workspace and --surface.")
            }
            let record = try latestAgentTurnDiffBaseline(
                repoRoot: repoRoot,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                env: ProcessInfo.processInfo.environment
            )
            _ = try gitStdout(["cat-file", "-e", "\(record.baseCommit)^{tree}"], in: repoRoot)
            patch = try gitStdout(["diff", "--no-ext-diff", "--binary", record.baseCommit, "--"], in: repoRoot)
            sourceLabel = "git last-turn \(workspaceId) \(surfaceId)"
        }
        return DiffInput(
            patch: patch,
            sourceLabel: sourceLabel,
            defaultTitle: source.title,
            emptyMessage: source.emptyMessage
        )
    }

    private func decodeDiffData(_ data: Data, sourceDescription: String) throws -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .ascii) {
            return text
        }
        throw CLIError(message: "Diff input is not valid UTF-8: \(sourceDescription)")
    }

    private func currentGitRepoRoot() throws -> String {
        try gitRepoRoot(startingAt: FileManager.default.currentDirectoryPath)
    }

    private func gitRepoRoot(startingAt directory: String) throws -> String {
        do {
            return try standardizedDiffSourcePath(gitSingleLine(["rev-parse", "--show-toplevel"], in: directory))
        } catch {
            throw CLIError(message: "cmux diff git sources require a git repository")
        }
    }

    private func gitBranchDiffBaseRef(in repoRoot: String) throws -> String {
        if let upstream = try? gitSingleLine(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: repoRoot),
           !upstream.isEmpty {
            return upstream
        }
        if let originHead = try? gitSingleLine(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: repoRoot),
           !originHead.isEmpty {
            return originHead
        }
        for candidate in ["origin/main", "origin/master", "upstream/main", "upstream/master", "main", "master"] {
            if (try? gitStdout(["rev-parse", "--verify", "--quiet", "\(candidate)^{commit}"], in: repoRoot)) != nil {
                return candidate
            }
        }
        throw CLIError(message: "Unable to find a branch diff base. Set an upstream branch or create origin/main.")
    }

    private func gitSingleLine(_ arguments: [String], in directory: String) throws -> String {
        let output = try gitStdout(arguments, in: directory)
        guard let line = output
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !line.isEmpty else {
            throw CLIError(message: "git returned empty output for \(arguments.joined(separator: " "))")
        }
        return line
    }

    private func gitStdout(
        _ arguments: [String],
        in directory: String,
        timeout: TimeInterval = 60
    ) throws -> String {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", directory] + arguments,
            timeout: timeout
        )
        if result.timedOut {
            throw CLIError(message: "git \(arguments.joined(separator: " ")) timed out")
        }
        guard result.status == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty ? stdout : stderr
            throw CLIError(message: detail.isEmpty ? "git \(arguments.joined(separator: " ")) failed" : detail)
        }
        return result.stdout
    }

    func recordAgentTurnDiffBaseline(
        agent: String,
        sessionId: String,
        turnId: String?,
        cwd: String?,
        workspaceId: String,
        surfaceId: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard let cwd = normalizedDiffSourceValue(cwd),
              let workspaceId = normalizedDiffSourceValue(workspaceId),
              let surfaceId = normalizedDiffSourceValue(surfaceId) else {
            return
        }
        let repoRoot = try gitRepoRoot(startingAt: cwd)
        let baseCommit = try agentTurnDiffBaselineCommit(in: repoRoot)
        let record = CMUXAgentTurnDiffBaselineRecord(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            sessionId: normalizedDiffSourceValue(sessionId) ?? "",
            turnId: normalizedDiffSourceValue(turnId),
            agent: normalizedDiffSourceValue(agent) ?? "agent",
            repoRoot: repoRoot,
            baseCommit: baseCommit,
            capturedAt: Date().timeIntervalSince1970
        )
        try updateAgentTurnDiffBaselineStore(path: CMUXAgentTurnDiffBaselineFile.path(env: env)) { store in
            store.records.removeAll { existing in
                guard standardizedDiffSourcePath(existing.repoRoot) == repoRoot,
                      existing.workspaceId == workspaceId,
                      existing.surfaceId == surfaceId,
                      existing.sessionId == record.sessionId else {
                    return false
                }
                if let turnId = record.turnId {
                    return existing.turnId == turnId
                }
                return existing.turnId == nil
            }
            store.records.append(record)
            pruneAgentTurnDiffBaselineStore(&store)
        }
    }

    private func agentTurnDiffBaselineCommit(in repoRoot: String) throws -> String {
        let stashResult = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", repoRoot, "stash", "create", "cmux last turn baseline"],
            timeout: 60
        )
        if stashResult.timedOut {
            throw CLIError(message: "git stash create timed out")
        }
        if stashResult.status == 0,
           let stashCommit = normalizedDiffSourceValue(stashResult.stdout) {
            return stashCommit
        }
        return try gitSingleLine(["rev-parse", "HEAD"], in: repoRoot)
    }

    private func latestAgentTurnDiffBaseline(
        repoRoot: String,
        workspaceId: String,
        surfaceId: String,
        env: [String: String]
    ) throws -> CMUXAgentTurnDiffBaselineRecord {
        let store = try readAgentTurnDiffBaselineStore(path: CMUXAgentTurnDiffBaselineFile.path(env: env))
        let repoRoot = standardizedDiffSourcePath(repoRoot)
        let candidates = store.records.filter { record in
            standardizedDiffSourcePath(record.repoRoot) == repoRoot
                && record.workspaceId == workspaceId
                && record.surfaceId == surfaceId
        }
        guard let record = candidates.max(by: { $0.capturedAt < $1.capturedAt }) else {
            throw CLIError(message: "No last-turn diff baseline recorded for this workspace and surface yet. Run another agent turn with cmux hooks active, or use --unstaged, --staged, or --branch.")
        }
        return record
    }

    private func readAgentTurnDiffBaselineStore(path: String) throws -> CMUXAgentTurnDiffBaselineStore {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CMUXAgentTurnDiffBaselineStore()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CMUXAgentTurnDiffBaselineStore.self, from: data)
    }

    private func updateAgentTurnDiffBaselineStore(
        path: String,
        update: (inout CMUXAgentTurnDiffBaselineStore) throws -> Void
    ) throws {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let lockPath = expandedPath + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        if fd < 0 {
            throw CLIError(message: "Failed to open diff baseline lock: \(lockPath)")
        }
        defer { Darwin.close(fd) }

        if flock(fd, LOCK_EX) != 0 {
            throw CLIError(message: "Failed to lock diff baseline store: \(expandedPath)")
        }
        defer { _ = flock(fd, LOCK_UN) }

        var store = (try? readAgentTurnDiffBaselineStore(path: expandedPath)) ?? CMUXAgentTurnDiffBaselineStore()
        try update(&store)

        let url = URL(fileURLWithPath: expandedPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(store).write(to: url, options: .atomic)
    }

    private func pruneAgentTurnDiffBaselineStore(_ store: inout CMUXAgentTurnDiffBaselineStore) {
        let cutoff = Date().timeIntervalSince1970 - 60 * 60 * 24 * 7
        store.records = store.records
            .filter { $0.capturedAt >= cutoff }
            .sorted { $0.capturedAt > $1.capturedAt }
        if store.records.count > 200 {
            store.records.removeSubrange(200..<store.records.count)
        }
    }

    private func normalizedDiffSourceValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func standardizedDiffSourcePath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }

    private func diffViewerAppearance(fontSizeOverride: Double?) -> DiffViewerAppearance {
        var appearance = defaultDiffViewerAppearance()
        for url in themeConfigSearchURLs() {
            guard let contents = readOptionalDiffViewerConfig(at: url) else { continue }
            applyDiffViewerGhosttyConfig(contents, to: &appearance)
        }
        if let fontSizeOverride {
            appearance.fontSize = fontSizeOverride
        }
        let themeSuffix = UUID().uuidString.prefix(8)
        appearance.lightTheme.generatedName = "cmux-ghostty-light-\(themeSuffix)"
        appearance.darkTheme.generatedName = "cmux-ghostty-dark-\(themeSuffix)"
        appearance.lightTheme.type = diffViewerThemeType(forBackground: appearance.lightTheme.background, fallback: "light")
        appearance.darkTheme.type = diffViewerThemeType(forBackground: appearance.darkTheme.background, fallback: "dark")
        return appearance
    }

    private func defaultDiffViewerAppearance() -> DiffViewerAppearance {
        var lightTheme = DiffViewerTheme(
            generatedName: "cmux-ghostty-light",
            ghosttyName: "Apple System Colors Light",
            type: "light",
            background: "#feffff",
            foreground: "#000000",
            selectionBackground: "#abd8ff",
            selectionForeground: "#000000",
            palette: [:]
        )
        applyDiffViewerThemeContents(diffViewerDefaultThemeConfigContents(preferredColorScheme: .light), to: &lightTheme)

        var darkTheme = DiffViewerTheme(
            generatedName: "cmux-ghostty-dark",
            ghosttyName: "Apple System Colors",
            type: "dark",
            background: "#1e1e1e",
            foreground: "#ffffff",
            selectionBackground: "#3f638b",
            selectionForeground: "#ffffff",
            palette: [:]
        )
        applyDiffViewerThemeContents(diffViewerDefaultThemeConfigContents(preferredColorScheme: .dark), to: &darkTheme)

        return DiffViewerAppearance(
            fontFamily: "Menlo",
            fontSize: 10,
            lightTheme: lightTheme,
            darkTheme: darkTheme
        )
    }

    private func applyDiffViewerGhosttyConfig(_ contents: String, to appearance: inout DiffViewerAppearance) {
        for line in contents.components(separatedBy: .newlines) {
            guard let (key, value) = diffViewerGhosttyAssignment(from: line) else { continue }

            switch key {
            case "font-family":
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    appearance.fontFamily = trimmed
                }
            case "theme":
                applyDiffViewerThemeDirective(value, to: &appearance)
            default:
                applyDiffViewerThemeAssignment(key: key, value: value, to: &appearance.lightTheme)
                applyDiffViewerThemeAssignment(key: key, value: value, to: &appearance.darkTheme)
            }
        }
    }

    private func applyDiffViewerThemeDirective(_ rawValue: String, to appearance: inout DiffViewerAppearance) {
        let lightThemeName = resolveDiffViewerThemeName(from: rawValue, preferredColorScheme: .light)
        if let theme = loadDiffViewerGhosttyTheme(
            named: lightThemeName,
            generatedName: "cmux-ghostty-light",
            fallbackType: "light",
            baseTheme: appearance.lightTheme
        ) {
            appearance.lightTheme = theme
        } else if !lightThemeName.isEmpty {
            appearance.lightTheme.ghosttyName = lightThemeName
        }

        let darkThemeName = resolveDiffViewerThemeName(from: rawValue, preferredColorScheme: .dark)
        if let theme = loadDiffViewerGhosttyTheme(
            named: darkThemeName,
            generatedName: "cmux-ghostty-dark",
            fallbackType: "dark",
            baseTheme: appearance.darkTheme
        ) {
            appearance.darkTheme = theme
        } else if !darkThemeName.isEmpty {
            appearance.darkTheme.ghosttyName = darkThemeName
        }
    }

    private func loadDiffViewerGhosttyTheme(
        named rawThemeName: String,
        generatedName: String,
        fallbackType: String,
        baseTheme: DiffViewerTheme
    ) -> DiffViewerTheme? {
        let themeName = rawThemeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !themeName.isEmpty else { return nil }

        for candidateName in diffViewerThemeNameCandidates(from: themeName) {
            for directoryURL in themeDirectoryURLs() {
                let themeURL = directoryURL.appendingPathComponent(candidateName, isDirectory: false)
                guard let contents = try? String(contentsOf: themeURL, encoding: .utf8) else {
                    continue
                }

                var theme = baseTheme
                theme.generatedName = generatedName
                theme.ghosttyName = candidateName
                applyDiffViewerThemeContents(contents, to: &theme)
                theme.type = diffViewerThemeType(forBackground: theme.background, fallback: fallbackType)
                return theme
            }
        }

        return nil
    }

    private func applyDiffViewerThemeContents(_ contents: String, to theme: inout DiffViewerTheme) {
        for line in contents.components(separatedBy: .newlines) {
            guard let (key, value) = diffViewerGhosttyAssignment(from: line) else { continue }
            applyDiffViewerThemeAssignment(key: key, value: value, to: &theme)
        }
    }

    private func applyDiffViewerThemeAssignment(key: String, value: String, to theme: inout DiffViewerTheme) {
        switch key {
        case "background":
            if let color = normalizedDiffViewerHexColor(value) {
                theme.background = color
            }
        case "foreground":
            if let color = normalizedDiffViewerHexColor(value) {
                theme.foreground = color
            }
        case "selection-background":
            if let color = normalizedDiffViewerHexColor(value) {
                theme.selectionBackground = color
            }
        case "selection-foreground":
            if let color = normalizedDiffViewerHexColor(value) {
                theme.selectionForeground = color
            }
        case "palette":
            let paletteParts = value.split(separator: "=", maxSplits: 1).map(String.init)
            guard paletteParts.count == 2,
                  let index = Int(paletteParts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  (0...15).contains(index),
                  let color = normalizedDiffViewerHexColor(paletteParts[1]) else {
                return
            }
            theme.palette[index] = color
        default:
            break
        }
    }

    private func readOptionalDiffViewerConfig(at url: URL) -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path) {
            if let type = attributes[.type] as? FileAttributeType,
               type != .typeRegular && type != .typeSymbolicLink {
                return nil
            }
            if let size = attributes[.size] as? NSNumber, size.intValue == 0 {
                return nil
            }
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func diffViewerGhosttyAssignment(from line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 2 else { return nil }

        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private func resolveDiffViewerThemeName(
        from rawThemeValue: String,
        preferredColorScheme: DiffViewerColorScheme
    ) -> String {
        var fallbackTheme: String?
        var lightTheme: String?
        var darkTheme: String?

        for token in rawThemeValue.split(separator: ",").map(String.init) {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count != 2 {
                if fallbackTheme == nil {
                    fallbackTheme = entry
                }
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "light":
                if lightTheme == nil {
                    lightTheme = value
                }
            case "dark":
                if darkTheme == nil {
                    darkTheme = value
                }
            default:
                if fallbackTheme == nil {
                    fallbackTheme = value
                }
            }
        }

        switch preferredColorScheme {
        case .light:
            if let lightTheme {
                return lightTheme
            }
        case .dark:
            if let darkTheme {
                return darkTheme
            }
        }

        if let fallbackTheme {
            return fallbackTheme
        }
        if let darkTheme {
            return darkTheme
        }
        if let lightTheme {
            return lightTheme
        }
        return rawThemeValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func diffViewerThemeNameCandidates(from rawName: String) -> [String] {
        var candidates: [String] = []
        let compatibilityAliasGroups = [
            ["Solarized Light", "iTerm2 Solarized Light"],
            ["Solarized Dark", "iTerm2 Solarized Dark"]
        ]

        func appendCandidate(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !candidates.contains(trimmed) {
                candidates.append(trimmed)
            }

            for group in compatibilityAliasGroups {
                if group.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                    for alias in group where alias.caseInsensitiveCompare(trimmed) != .orderedSame {
                        if !candidates.contains(alias) {
                            candidates.append(alias)
                        }
                    }
                }
            }
        }

        var queue: [String] = [rawName]
        while let current = queue.popLast() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            appendCandidate(trimmed)

            let lower = trimmed.lowercased()
            if lower.hasPrefix("builtin ") {
                let stripped = String(trimmed.dropFirst("builtin ".count))
                appendCandidate(stripped)
                queue.append(stripped)
            }

            if let range = trimmed.range(
                of: #"\s*\(builtin\)\s*$"#,
                options: [.regularExpression, .caseInsensitive]
            ) {
                let stripped = String(trimmed[..<range.lowerBound])
                appendCandidate(stripped)
                queue.append(stripped)
            }
        }

        return candidates
    }

    private func normalizedDiffViewerHexColor(_ rawValue: String) -> String? {
        var hex = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard !hex.isEmpty, hex.allSatisfy(\.isHexDigit) else { return nil }

        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 else { return nil }
        return "#\(hex.lowercased())"
    }

    private func diffViewerThemeType(forBackground background: String, fallback: String) -> String {
        guard let rgb = diffViewerRGBColor(background) else {
            return fallback
        }
        let luminance = (0.2126 * rgb.red) + (0.7152 * rgb.green) + (0.0722 * rgb.blue)
        return luminance > 0.55 ? "light" : "dark"
    }

    private func diffViewerRGBColor(_ rawValue: String) -> (red: Double, green: Double, blue: Double)? {
        guard let color = normalizedDiffViewerHexColor(rawValue) else { return nil }
        let hex = String(color.dropFirst())
        guard let value = UInt32(hex, radix: 16) else { return nil }
        return (
            red: Double((value & 0xFF0000) >> 16) / 255.0,
            green: Double((value & 0x00FF00) >> 8) / 255.0,
            blue: Double(value & 0x0000FF) / 255.0
        )
    }

    private func isUsableDiffViewerFontSize(_ size: Double) -> Bool {
        size.isFinite && size > 0 && size <= 96
    }

    private func roundedDiffViewerMetric(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private func diffViewerDefaultThemeConfigContents(preferredColorScheme: DiffViewerColorScheme) -> String {
        switch preferredColorScheme {
        case .light:
            return """
            palette = 0=#1a1a1a
            palette = 1=#cc372e
            palette = 2=#26a439
            palette = 3=#cdac08
            palette = 4=#0869cb
            palette = 5=#9647bf
            palette = 6=#479ec2
            palette = 7=#98989d
            palette = 8=#464646
            palette = 9=#ff453a
            palette = 10=#32d74b
            palette = 11=#e5bc00
            palette = 12=#0a84ff
            palette = 13=#bf5af2
            palette = 14=#69c9f2
            palette = 15=#ffffff
            background = #feffff
            foreground = #000000
            selection-background = #abd8ff
            selection-foreground = #000000
            """
        case .dark:
            return """
            palette = 0=#1a1a1a
            palette = 1=#cc372e
            palette = 2=#26a439
            palette = 3=#cdac08
            palette = 4=#0869cb
            palette = 5=#9647bf
            palette = 6=#479ec2
            palette = 7=#98989d
            palette = 8=#464646
            palette = 9=#ff453a
            palette = 10=#32d74b
            palette = 11=#ffd60a
            palette = 12=#0a84ff
            palette = 13=#bf5af2
            palette = 14=#76d6ff
            palette = 15=#ffffff
            background = #1e1e1e
            foreground = #ffffff
            selection-background = #3f638b
            selection-foreground = #ffffff
            """
        }
    }

    private func writeDiffViewerHTML(
        patch: String,
        title: String,
        sourceLabel: String,
        layout: String,
        appearance: DiffViewerAppearance
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-diff-viewer", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pruneDiffViewerFiles(in: directory)

        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "diff-\(timestamp)-\(UUID().uuidString.prefix(8)).html"
        let viewerURL = directory.appendingPathComponent(filename, isDirectory: false)
        let payload: [String: Any] = [
            "patch": patch,
            "title": title,
            "sourceLabel": sourceLabel,
            "layout": layout,
            "appearance": appearance.jsonObject,
            "generatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        let payloadLiteral = try jsonScriptLiteral(payload)
        let escapedTitle = htmlEscaped(title)
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapedTitle)</title>
          <style>
            :root {
              color-scheme: light dark;
              --cmux-diff-bg-light: #fff;
              --cmux-diff-bg-dark: #000;
              --cmux-diff-fg-light: #000;
              --cmux-diff-fg-dark: #fff;
              --cmux-diff-selection-bg-light: #abd8ff;
              --cmux-diff-selection-bg-dark: #3f638b;
              --cmux-diff-font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
              --cmux-diff-font-size: 10px;
              --cmux-diff-line-height: 15.38px;
              --cmux-diff-bg: var(--cmux-diff-bg-light);
              --cmux-diff-fg: var(--cmux-diff-fg-light);
              background: var(--cmux-diff-bg);
              color: var(--cmux-diff-fg);
            }
            @media (prefers-color-scheme: dark) {
              :root {
                --cmux-diff-bg: var(--cmux-diff-bg-dark);
                --cmux-diff-fg: var(--cmux-diff-fg-dark);
              }
            }
            * {
              box-sizing: border-box;
            }
            html,
            body {
              height: 100%;
              overflow: hidden;
            }
            body {
              margin: 0;
              height: 100vh;
              min-height: 0;
              background: var(--cmux-diff-bg);
              color: var(--cmux-diff-fg);
            }
            #viewer {
              --diffs-font-family: var(--cmux-diff-font-family);
              --diffs-header-font-family: var(--cmux-diff-font-family);
              --diffs-font-size: var(--cmux-diff-font-size);
              --diffs-line-height: var(--cmux-diff-line-height);
              --diffs-bg-selection-override: light-dark(var(--cmux-diff-selection-bg-light), var(--cmux-diff-selection-bg-dark));
              height: 100vh;
              min-height: 0;
              overflow: auto;
              background: inherit;
            }
            #viewer diffs-container {
              --diffs-font-family: var(--cmux-diff-font-family);
              --diffs-header-font-family: var(--cmux-diff-font-family);
              --diffs-font-size: var(--cmux-diff-font-size);
              --diffs-line-height: var(--cmux-diff-line-height);
              --diffs-bg-selection-override: light-dark(var(--cmux-diff-selection-bg-light), var(--cmux-diff-selection-bg-dark));
            }
            #status {
              padding: 16px;
              font-family: var(--cmux-diff-font-family);
              font-size: var(--cmux-diff-font-size);
              line-height: var(--cmux-diff-line-height);
              color: color-mix(in lab, var(--cmux-diff-fg) 70%, var(--cmux-diff-bg));
            }
            #status[data-error="true"] {
              color: light-dark(#b42318, #ff8a80);
            }
          </style>
        </head>
        <body>
          <main id="viewer" aria-label="Diff viewer">
            <div id="status">Loading diff...</div>
          </main>
          <script type="module">
            import { CodeView, getFiletypeFromFileName, parsePatchFiles, preloadHighlighter, registerCustomTheme } from "https://esm.run/@pierre/diffs@1.2.1";

            const payload = \(payloadLiteral);
            const viewerElement = document.getElementById("viewer");
            const status = document.getElementById("status");
            document.title = payload.title;
            applyViewerAppearance(payload.appearance);
            registerGhosttyTheme(payload.appearance.themes.light);
            registerGhosttyTheme(payload.appearance.themes.dark);
            stabilizeCodeViewStickyPositioning();

            try {
              const patches = parsePatchFiles(payload.patch, "cmux-diff");
              const items = patches.flatMap((patch, patchIndex) =>
                patch.files.map((fileDiff, fileIndex) => ({
                  id: `patch-${patchIndex}-file-${fileIndex}`,
                  type: "diff",
                  fileDiff,
                }))
              );

              if (items.length === 0) {
                throw new Error("No file diffs found in patch input.");
              }

              status.textContent = "Loading theme...";
              await preloadDiffHighlighter(payload.appearance, items);
              status.remove();
              const codeView = new CodeView({
                diffStyle: payload.layout,
                itemMetrics: {
                  lineHeight: payload.appearance.lineHeight,
                  diffHeaderHeight: payload.appearance.diffHeaderHeight,
                  spacing: 8,
                },
                stickyHeaders: true,
                theme: payload.appearance.theme,
                themeType: "system",
              });
              codeView.setup(viewerElement);
              codeView.setItems(items);
              codeView.render(true);
              renderUntilCodeViewReady(codeView, viewerElement, performance.now());
            } catch (error) {
              status.dataset.error = "true";
              status.textContent = error instanceof Error ? error.message : String(error);
            }

            function applyViewerAppearance(appearance) {
              const rootStyle = document.documentElement.style;
              rootStyle.setProperty("--cmux-diff-bg-light", appearance.themes.light.background);
              rootStyle.setProperty("--cmux-diff-bg-dark", appearance.themes.dark.background);
              rootStyle.setProperty("--cmux-diff-fg-light", appearance.themes.light.foreground);
              rootStyle.setProperty("--cmux-diff-fg-dark", appearance.themes.dark.foreground);
              rootStyle.setProperty("--cmux-diff-selection-bg-light", appearance.themes.light.selectionBackground);
              rootStyle.setProperty("--cmux-diff-selection-bg-dark", appearance.themes.dark.selectionBackground);
              rootStyle.setProperty("--cmux-diff-font-family", cssFontFamily(appearance.fontFamily));
              rootStyle.setProperty("--cmux-diff-font-size", `${appearance.fontSize}px`);
              rootStyle.setProperty("--cmux-diff-line-height", `${appearance.lineHeight}px`);
            }

            function cssFontFamily(fontFamily) {
              const family = typeof fontFamily === "string" && fontFamily.trim() !== "" ? fontFamily.trim() : "Menlo";
              return `${JSON.stringify(family)}, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace`;
            }

            function registerGhosttyTheme(theme) {
              registerCustomTheme(theme.name, () => Promise.resolve(shikiThemeFromGhostty(theme)));
            }

            function stabilizeCodeViewStickyPositioning() {
              const prototype = CodeView.prototype;
              if (prototype.__cmuxStableStickyPositioning === true || typeof prototype.applyStickyPositioning !== "function") {
                return;
              }

              prototype.__cmuxStableStickyPositioning = true;
              prototype.applyStickyPositioning = function({ stickyTop, stickyBottom }) {
                const height = this.getHeight();
                const itemMetrics = this.itemMetricsCache;
                const stickyContainerHeight = stickyBottom - stickyTop;
                this.renderState.stickyHeight = stickyContainerHeight;
                this.renderState.stickyTop = stickyTop;
                this.renderState.stickyBottom = stickyBottom;
                this.stickyOffset.style.height = `${stickyTop}px`;
                const stickyOffset = -Math.max(stickyContainerHeight, 0) + height;
                this.stickyContainer.style.top = `${stickyOffset}px`;
                this.stickyContainer.style.bottom = `${stickyOffset + itemMetrics.diffHeaderHeight}px`;
              };
            }

            function preloadDiffHighlighter(appearance, items) {
              const themes = Array.from(new Set([
                appearance.theme?.light,
                appearance.theme?.dark,
              ].filter(Boolean)));
              const langs = Array.from(new Set(items.map((item) => {
                const fileDiff = item.fileDiff ?? {};
                const name = fileDiff.name ?? fileDiff.newName ?? fileDiff.oldName ?? "";
                return fileDiff.lang ?? getFiletypeFromFileName(name) ?? "text";
              }).filter(Boolean)));
              return preloadHighlighter({
                themes,
                langs: langs.length > 0 ? langs : ["text"],
              });
            }

            function shikiThemeFromGhostty(theme) {
              const palette = theme.palette ?? {};
              const foreground = theme.foreground;
              const background = theme.background;
              return {
                name: theme.name,
                displayName: theme.ghosttyName,
                type: theme.type,
                colors: {
                  "editor.background": background,
                  "editor.foreground": foreground,
                  "terminal.background": background,
                  "terminal.foreground": foreground,
                  "terminal.ansiBlack": palette["0"] ?? foreground,
                  "terminal.ansiRed": palette["1"] ?? foreground,
                  "terminal.ansiGreen": palette["2"] ?? foreground,
                  "terminal.ansiYellow": palette["3"] ?? foreground,
                  "terminal.ansiBlue": palette["4"] ?? foreground,
                  "terminal.ansiMagenta": palette["5"] ?? foreground,
                  "terminal.ansiCyan": palette["6"] ?? foreground,
                  "terminal.ansiWhite": palette["7"] ?? foreground,
                  "terminal.ansiBrightBlack": palette["8"] ?? foreground,
                  "terminal.ansiBrightRed": palette["9"] ?? palette["1"] ?? foreground,
                  "terminal.ansiBrightGreen": palette["10"] ?? palette["2"] ?? foreground,
                  "terminal.ansiBrightYellow": palette["11"] ?? palette["3"] ?? foreground,
                  "terminal.ansiBrightBlue": palette["12"] ?? palette["4"] ?? foreground,
                  "terminal.ansiBrightMagenta": palette["13"] ?? palette["5"] ?? foreground,
                  "terminal.ansiBrightCyan": palette["14"] ?? palette["6"] ?? foreground,
                  "terminal.ansiBrightWhite": palette["15"] ?? foreground,
                  "gitDecoration.addedResourceForeground": palette["10"] ?? palette["2"] ?? "#32d74b",
                  "gitDecoration.deletedResourceForeground": palette["9"] ?? palette["1"] ?? "#ff453a",
                  "gitDecoration.modifiedResourceForeground": palette["12"] ?? palette["4"] ?? "#0a84ff",
                  "editor.selectionBackground": theme.selectionBackground,
                  "editor.selectionForeground": theme.selectionForeground,
                },
                tokenColors: [
                  { settings: { foreground, background } },
                  { scope: ["comment", "punctuation.definition.comment"], settings: { foreground: palette["8"] ?? foreground, fontStyle: "italic" } },
                  { scope: ["string", "constant.other.symbol"], settings: { foreground: palette["2"] ?? foreground } },
                  { scope: ["constant.numeric", "constant.language", "support.constant"], settings: { foreground: palette["3"] ?? foreground } },
                  { scope: ["keyword", "storage", "storage.type"], settings: { foreground: palette["5"] ?? foreground } },
                  { scope: ["entity.name.function", "support.function"], settings: { foreground: palette["4"] ?? foreground } },
                  { scope: ["entity.name.type", "entity.name.class", "support.type"], settings: { foreground: palette["6"] ?? foreground } },
                  { scope: ["variable", "meta.definition.variable"], settings: { foreground } },
                  { scope: ["invalid", "message.error"], settings: { foreground: palette["9"] ?? palette["1"] ?? foreground } },
                ],
              };
            }

            function renderUntilCodeViewReady(codeView, root, startedAt) {
              codeView.render(true);
              forceRenderReadyCodeViewItems(codeView);
              const hasRenderedContent = Array.from(root.querySelectorAll("diffs-container")).some((container) =>
                container.shadowRoot?.querySelector("[data-diffs-header], [data-line]")
              );
              if (!hasRenderedContent && performance.now() - startedAt < 10_000) {
                window.requestAnimationFrame(() => renderUntilCodeViewReady(codeView, root, startedAt));
              }
            }

            function forceRenderReadyCodeViewItems(codeView) {
              for (const renderedItem of codeView.getRenderedItems()) {
                if (renderedItem.type !== "diff") {
                  continue;
                }

                const hasRenderedContent = renderedItem.element.shadowRoot?.querySelector("[data-diffs-header], [data-line]");
                const hasReadyResult = renderedItem.instance?.hunksRenderer?.renderCache?.result != null;
                if (hasRenderedContent || !hasReadyResult) {
                  continue;
                }

                renderedItem.instance.render({
                  fileContainer: renderedItem.element,
                  fileDiff: renderedItem.item.fileDiff,
                  forceRender: true,
                  renderRange: renderedItem.instance.renderRange,
                });
              }
            }
          </script>
        </body>
        </html>
        """
        try html.write(to: viewerURL, atomically: true, encoding: .utf8)
        return viewerURL
    }

    private func jsonScriptLiteral(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Failed to encode diff viewer payload")
        }
        return text.replacingOccurrences(of: "</", with: "<\\/")
    }

    private func htmlEscaped(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func pruneDiffViewerFiles(in directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        let sorted = entries.compactMap { url -> (url: URL, date: Date)? in
            guard url.pathExtension == "html",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        for (index, entry) in sorted.enumerated() where index >= 50 || now.timeIntervalSince(entry.date) > 24 * 60 * 60 {
            try? FileManager.default.removeItem(at: entry.url)
        }
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

        Render a unified diff or patch with Diffs CodeView in a cmux browser split.
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
          --focus <true|false>         Focus the diff browser split (default: false)
          --no-focus                   Do not focus the diff browser split
          --title <text>               Diff viewer title
          --layout <split|unified>     Diff layout (default: split)
          --font-size <points>         Set diff font size (default: 10)

        Examples:
          cmux diff changes.patch
          git diff | cmux diff
          cmux diff --unstaged
          cmux diff --staged
          cmux diff --branch
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
