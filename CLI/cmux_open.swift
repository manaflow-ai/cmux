import Foundation

extension CMUXCLI {
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
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (windowOpt, rem1) = parseOption(rem0, name: "--window")
        let (surfaceOpt, rem2) = parseOption(rem1, name: "--surface")
        let (paneOpt, rem3) = parseOption(rem2, name: "--pane")
        let (focusOpt, rem4) = parseOption(rem3, name: "--focus")
        let remaining = rem4.filter { $0 != "--" && $0 != "--no-focus" }

        if let unknownFlag = remaining.first(where: { $0.hasPrefix("-") }) {
            throw CLIError(message: "open: unknown flag '\(unknownFlag)'. Usage: cmux open <path-or-url>... [--workspace <id|ref|index>] [--surface <id|ref|index>] [--pane <id|ref|index>] [--window <id|ref|index>] [--focus true|false] [--no-focus]")
        }
        guard !remaining.isEmpty else {
            throw CLIError(message: "open requires at least one path or URL. Usage: cmux open <path-or-url>...")
        }

        let focus: Bool
        if hasFlag(commandArgs, name: "--no-focus") {
            focus = false
        } else if let focusOpt {
            guard let parsed = parseBoolString(focusOpt) else {
                throw CLIError(message: "--focus must be true|false")
            }
            focus = parsed
        } else {
            focus = true
        }

        let targets = try remaining.map(resolveOpenTarget)
        let directories = targets.compactMap { target -> String? in
            guard case .directory(let path) = target else { return nil }
            return path
        }
        let files = targets.compactMap { target -> String? in
            guard case .file(let path) = target else { return nil }
            return path
        }
        let urls = targets.compactMap { target -> String? in
            guard case .url(let url) = target else { return nil }
            return url
        }

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        let windowHandle = try normalizeWindowHandle(windowOpt, client: client)
        let workspaceRaw = workspaceOpt ?? (windowOpt == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle)
        let surfaceRaw = surfaceOpt ?? (windowOpt == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle)
        let paneHandle = try normalizePaneHandle(paneOpt, client: client, workspaceHandle: workspaceHandle)

        var payloads: [[String: Any]] = []
        for directory in directories {
            var params: [String: Any] = ["cwd": directory]
            if let windowHandle { params["window_id"] = windowHandle }
            let payload = try client.sendV2(method: "workspace.create", params: params)
            payloads.append(["kind": "workspace", "payload": payload, "path": directory])
        }

        if !files.isEmpty {
            var params: [String: Any] = ["paths": files, "focus": focus]
            if let windowHandle { params["window_id"] = windowHandle }
            if let workspaceHandle { params["workspace_id"] = workspaceHandle }
            if let surfaceHandle { params["surface_id"] = surfaceHandle }
            if let paneHandle { params["pane_id"] = paneHandle }
            let payload = try client.sendV2(method: "file.open", params: params)
            payloads.append(["kind": "file", "payload": payload])
        }

        for url in urls {
            var params: [String: Any] = ["url": url, "focus": focus]
            if let windowHandle { params["window_id"] = windowHandle }
            if let workspaceHandle { params["workspace_id"] = workspaceHandle }
            if let surfaceHandle { params["surface_id"] = surfaceHandle }
            let payload = try client.sendV2(method: "browser.open_split", params: params)
            payloads.append(["kind": "url", "payload": payload, "url": url])
        }

        if jsonOutput {
            print(jsonString(formatIDs(["opened": payloads], mode: idFormat)))
            return
        }

        print(openCommandSummary(
            payloads: payloads,
            fileCount: files.count,
            urlCount: urls.count,
            directoryCount: directories.count,
            idFormat: idFormat
        ))
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
