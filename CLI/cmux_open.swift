import Foundation

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

    private func openOptionValue(_ args: [String], index: Int, name: String) throws -> String {
        guard index + 1 < args.count else {
            throw CLIError(message: "\(name) requires a value")
        }
        return args[index + 1]
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
        Files open in file preview tabs and infer the preview UI from the file type.
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
