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

    private struct DiffArguments {
        var workspace: String?
        var window: String?
        var surface: String?
        var focus: String?
        var noFocus = false
        var title: String?
        var layout: String?
        var inputs: [String] = []
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

        let input = try readDiffInput(parsedArgs.inputs.first)
        let trimmedPatch = input.patch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPatch.isEmpty else {
            throw CLIError(message: "diff input is empty")
        }

        let title = parsedArgs.title ?? input.defaultTitle
        let viewerURL = try writeDiffViewerHTML(
            patch: input.patch,
            title: title,
            sourceLabel: input.sourceLabel,
            layout: layout
        )

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

        var params: [String: Any] = [
            "url": viewerURL.absoluteString,
            "focus": focus
        ]
        if let windowHandle { params["window_id"] = windowHandle }
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let surfaceHandle { params["surface_id"] = surfaceHandle }

        let payload = try client.sendV2(method: "browser.open_split", params: params)

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
                default:
                    if arg.hasPrefix("-"), arg != "-" {
                        throw CLIError(message: "diff: unknown flag '\(arg)'. Usage: cmux diff [patch-file|-] [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--focus true|false] [--no-focus] [--title <text>] [--layout split|unified]")
                    }
                }
            }

            parsed.inputs.append(arg)
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

    private func diffOptionValue(_ args: [String], index: Int, name: String) throws -> String {
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

    private func readDiffInput(_ rawInput: String?) throws -> (patch: String, sourceLabel: String, defaultTitle: String) {
        guard let rawInput, rawInput != "-" else {
            guard isatty(STDIN_FILENO) == 0 else {
                throw CLIError(message: "diff requires a patch file or piped stdin. Usage: cmux diff <patch-file>|-")
            }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return (try decodeDiffData(data, sourceDescription: "stdin"), "stdin", "cmux diff")
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
        return (try decodeDiffData(data, sourceDescription: resolved), resolved, filename.isEmpty ? "cmux diff" : filename)
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

    private func writeDiffViewerHTML(
        patch: String,
        title: String,
        sourceLabel: String,
        layout: String
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
              background: light-dark(#fff, #000);
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
              background: light-dark(#fff, #000);
            }
            #viewer {
              height: 100vh;
              min-height: 0;
              overflow: auto;
              background: inherit;
            }
            #status {
              padding: 16px;
              font: 13px/20px ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
              color: light-dark(#57606a, #a6adb7);
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
            import { CodeView, parsePatchFiles } from "https://esm.run/@pierre/diffs@1.2.1";

            const payload = \(payloadLiteral);
            const viewerElement = document.getElementById("viewer");
            const status = document.getElementById("status");
            document.title = payload.title;

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

              status.remove();
              const codeView = new CodeView({
                diffStyle: payload.layout,
              });
              codeView.setup(viewerElement);
              codeView.setItems(items);
              codeView.render(true);
              renderUntilCodeViewReady(codeView, viewerElement, performance.now());
            } catch (error) {
              status.dataset.error = "true";
              status.textContent = error instanceof Error ? error.message : String(error);
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
        With no patch file, cmux diff reads piped stdin.

        Options:
          --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
          --surface <id|ref|index>     Source surface to split from (default: $CMUX_SURFACE_ID)
          --window <id|ref|index>      Target window
          --focus <true|false>         Focus the diff browser split (default: false)
          --no-focus                   Do not focus the diff browser split
          --title <text>               Diff viewer title
          --layout <split|unified>     Diff layout (default: split)

        Examples:
          cmux diff changes.patch
          git diff | cmux diff
          cmux diff pr.patch --layout unified --focus true
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
