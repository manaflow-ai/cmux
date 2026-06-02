import Foundation

final class CMUXBrowserMCPServer {
    private let cli: CMUXCLI
    private let socketPath: String
    private let explicitPassword: String?
    private var defaultSurface: String?

    init(cli: CMUXCLI, socketPath: String, explicitPassword: String?) {
        self.cli = cli
        self.socketPath = socketPath
        self.explicitPassword = explicitPassword
    }

    func run() throws {
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            do {
                try handleMessageLine(trimmed)
            } catch {
                writeStderr("cmux browser MCP: \(error)\n")
            }
        }
    }

    private func handleMessageLine(_ line: String) throws {
        guard let data = line.data(using: .utf8) else {
            throw CLIError(message: "Invalid UTF-8 MCP message")
        }
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        if let batch = object as? [[String: Any]] {
            for message in batch {
                handleMessage(message)
            }
            return
        }
        guard let message = object as? [String: Any] else {
            throw CLIError(message: "Invalid MCP message")
        }
        handleMessage(message)
    }

    private func handleMessage(_ message: [String: Any]) {
        guard let method = message["method"] as? String else { return }
        let id = message["id"]

        if id == nil {
            handleNotification(method: method)
            return
        }

        do {
            let result: Any
            switch method {
            case "initialize":
                result = initializeResult(params: message["params"] as? [String: Any])
            case "ping":
                result = [:] as [String: Any]
            case "tools/list":
                result = ["tools": toolDefinitions()]
            case "tools/call":
                result = try handleToolCall(params: message["params"] as? [String: Any])
            default:
                writeError(id: id, code: -32601, message: "Method not found: \(method)")
                return
            }
            writeResponse(id: id, result: result)
        } catch {
            writeError(id: id, code: -32603, message: String(describing: error))
        }
    }

    private func handleNotification(method: String) {
        if method != "notifications/initialized" {
            writeStderr("cmux browser MCP: ignored notification \(method)\n")
        }
    }

    private func initializeResult(params: [String: Any]?) -> [String: Any] {
        let requestedVersion = params?["protocolVersion"] as? String
        return [
            "protocolVersion": requestedVersion ?? "2025-06-18",
            "capabilities": [
                "tools": [
                    "listChanged": false,
                ],
            ],
            "serverInfo": [
                "name": "cmux-browser",
                "version": Self.versionString(),
            ],
        ]
    }

    private func handleToolCall(params: [String: Any]?) throws -> [String: Any] {
        guard let params,
              let name = params["name"] as? String else {
            throw CLIError(message: "tools/call requires a tool name")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            switch name {
            case "cmux_browser_identify":
                return try toolJSON(callIdentify(arguments))
            case "cmux_browser_open":
                return try toolJSON(callOpen(arguments))
            case "cmux_browser_navigate":
                return try toolJSON(callNavigate(arguments))
            case "cmux_browser_snapshot":
                let payload = try callSnapshot(arguments)
                return toolText((payload["snapshot"] as? String) ?? compactJSONString(payload))
            case "cmux_browser_click":
                return try toolJSON(callSimpleSelector(arguments, method: "browser.click", label: "click"))
            case "cmux_browser_fill":
                return try toolJSON(callTextInput(arguments, method: "browser.fill", label: "fill", allowEmptyText: true))
            case "cmux_browser_type":
                return try toolJSON(callTextInput(arguments, method: "browser.type", label: "type", allowEmptyText: false))
            case "cmux_browser_wait":
                return try toolJSON(callWait(arguments))
            case "cmux_browser_get":
                return try toolJSON(callGet(arguments))
            case "cmux_browser_eval":
                return try toolJSON(callEval(arguments))
            case "cmux_browser_screenshot":
                return try toolJSON(callScreenshot(arguments))
            case "cmux_browser_console":
                return try toolJSON(callLogList(arguments, namespace: "console"))
            case "cmux_browser_errors":
                return try toolJSON(callLogList(arguments, namespace: "errors"))
            case "cmux_browser_rpc":
                return try toolJSON(callRawBrowserRPC(arguments))
            default:
                throw CLIError(message: "Unknown cmux browser MCP tool: \(name)")
            }
        } catch {
            return toolText(String(describing: error), isError: true)
        }
    }

    private func withClient<T>(_ body: (SocketClient) throws -> T) throws -> T {
        let client = try cli.connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: false
        )
        defer { client.close() }
        return try body(client)
    }

    private func resolveSurface(_ arguments: [String: Any], client: SocketClient) throws -> String {
        let raw = stringArgument(arguments, keys: ["surface", "surface_id"]) ??
            defaultSurface ??
            ProcessInfo.processInfo.environment["CMUX_BROWSER_SURFACE_ID"]
        guard let raw,
              let surface = try cli.normalizeSurfaceHandle(raw, client: client) else {
            throw CLIError(message: "A browser surface is required. Call cmux_browser_open first or pass surface.")
        }
        defaultSurface = surface
        return surface
    }

    private func rememberSurface(from payload: [String: Any]) {
        if let surface = payload["surface_id"] as? String ?? payload["surface_ref"] as? String {
            defaultSurface = surface
        } else if let surface = payload["surface"] as? String {
            defaultSurface = surface
        }
    }

    private func callIdentify(_ arguments: [String: Any]) throws -> [String: Any] {
        try withClient { client in
            let surfaceRaw = stringArgument(arguments, keys: ["surface", "surface_id"])
            var payload = try client.sendV2(method: "system.identify")
            if let surfaceRaw,
               let surface = try cli.normalizeSurfaceHandle(surfaceRaw, client: client) {
                let urlPayload = try client.sendV2(method: "browser.url.get", params: ["surface_id": surface])
                let titlePayload = try client.sendV2(method: "browser.get.title", params: ["surface_id": surface])
                payload["browser"] = [
                    "surface": surface,
                    "url": urlPayload["url"] ?? "",
                    "title": titlePayload["title"] ?? "",
                ]
                defaultSurface = surface
            }
            return payload
        }
    }

    private func callOpen(_ arguments: [String: Any]) throws -> [String: Any] {
        try withClient { client in
            var params: [String: Any] = [:]
            if let url = stringArgument(arguments, keys: ["url"]) {
                params["url"] = url
            }
            if let workspaceRaw = stringArgument(arguments, keys: ["workspace", "workspace_id"]) ??
                (stringArgument(arguments, keys: ["window", "window_id"]) == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil),
               let workspace = try cli.normalizeWorkspaceHandle(workspaceRaw, client: client) {
                params["workspace_id"] = workspace
            }
            if let windowRaw = stringArgument(arguments, keys: ["window", "window_id"]),
               let window = try cli.normalizeWindowHandle(windowRaw, client: client) {
                params["window_id"] = window
            }
            if let focus = boolArgument(arguments, key: "focus") {
                params["focus"] = focus
            }
            let payload = try client.sendV2(method: "browser.open_split", params: params)
            rememberSurface(from: payload)
            return payload
        }
    }

    private func callNavigate(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let url = stringArgument(arguments, keys: ["url"]) else {
            throw CLIError(message: "cmux_browser_navigate requires url")
        }
        return try withClient { client in
            let surface = try resolveSurface(arguments, client: client)
            var params: [String: Any] = ["surface_id": surface, "url": url]
            if boolArgument(arguments, key: "snapshot_after") == true {
                params["snapshot_after"] = true
            }
            return try client.sendV2(method: "browser.navigate", params: params)
        }
    }

    private func callSnapshot(_ arguments: [String: Any]) throws -> [String: Any] {
        try withClient { client in
            let surface = try resolveSurface(arguments, client: client)
            var params: [String: Any] = ["surface_id": surface]
            params["interactive"] = boolArgument(arguments, key: "interactive") ?? true
            if boolArgument(arguments, key: "compact") == true {
                params["compact"] = true
            }
            if boolArgument(arguments, key: "cursor") == true {
                params["cursor"] = true
            }
            if let selector = stringArgument(arguments, keys: ["selector"]) {
                params["selector"] = selector
            }
            if let maxDepth = intArgument(arguments, key: "max_depth") ?? intArgument(arguments, key: "maxDepth") {
                params["max_depth"] = maxDepth
            }
            return try client.sendV2(method: "browser.snapshot", params: params)
        }
    }

    private func callSimpleSelector(_ arguments: [String: Any], method: String, label: String) throws -> [String: Any] {
        guard let selector = stringArgument(arguments, keys: ["selector", "ref"]) else {
            throw CLIError(message: "cmux_browser_\(label) requires selector")
        }
        return try withClient { client in
            let surface = try resolveSurface(arguments, client: client)
            var params: [String: Any] = ["surface_id": surface, "selector": selector]
            if boolArgument(arguments, key: "snapshot_after") == true {
                params["snapshot_after"] = true
            }
            return try client.sendV2(method: method, params: params)
        }
    }

    private func callTextInput(
        _ arguments: [String: Any],
        method: String,
        label: String,
        allowEmptyText: Bool
    ) throws -> [String: Any] {
        guard let selector = stringArgument(arguments, keys: ["selector", "ref"]) else {
            throw CLIError(message: "cmux_browser_\(label) requires selector")
        }
        guard let text = stringArgument(arguments, keys: ["text"]),
              allowEmptyText || !text.isEmpty else {
            throw CLIError(message: "cmux_browser_\(label) requires text")
        }
        return try withClient { client in
            let surface = try resolveSurface(arguments, client: client)
            var params: [String: Any] = ["surface_id": surface, "selector": selector, "text": text]
            if boolArgument(arguments, key: "snapshot_after") == true {
                params["snapshot_after"] = true
            }
            return try client.sendV2(method: method, params: params)
        }
    }

    private func callWait(_ arguments: [String: Any]) throws -> [String: Any] {
        try withClient { client in
            let surface = try resolveSurface(arguments, client: client)
            var params: [String: Any] = ["surface_id": surface]
            copyString(arguments, from: "selector", to: "selector", into: &params)
            copyString(arguments, from: "text", to: "text_contains", into: &params)
            copyString(arguments, from: "text_contains", to: "text_contains", into: &params)
            copyString(arguments, from: "url_contains", to: "url_contains", into: &params)
            copyString(arguments, from: "load_state", to: "load_state", into: &params)
            copyString(arguments, from: "function", to: "function", into: &params)
            if let timeoutMs = intArgument(arguments, key: "timeout_ms") ?? intArgument(arguments, key: "timeoutMs") {
                params["timeout_ms"] = timeoutMs
            }
            let responseTimeout = ((params["timeout_ms"] as? Int).map { Double(max(1, $0)) / 1000.0 + 5.0 })
            return try client.sendV2(method: "browser.wait", params: params, responseTimeout: responseTimeout)
        }
    }

    private func callGet(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let rawKind = stringArgument(arguments, keys: ["kind", "target"]) else {
            throw CLIError(message: "cmux_browser_get requires kind")
        }
        let kind = rawKind.lowercased()
        let methodMap: [String: String] = [
            "url": "browser.url.get",
            "title": "browser.get.title",
            "text": "browser.get.text",
            "html": "browser.get.html",
            "value": "browser.get.value",
            "attr": "browser.get.attr",
            "count": "browser.get.count",
            "box": "browser.get.box",
            "styles": "browser.get.styles",
        ]
        guard let method = methodMap[kind] else {
            throw CLIError(message: "Unsupported cmux_browser_get kind: \(kind)")
        }
        return try withClient { client in
            let surface = try resolveSurface(arguments, client: client)
            var params: [String: Any] = ["surface_id": surface]
            if !["url", "title"].contains(kind) {
                guard let selector = stringArgument(arguments, keys: ["selector", "ref"]) else {
                    throw CLIError(message: "cmux_browser_get kind \(kind) requires selector")
                }
                params["selector"] = selector
            }
            if kind == "attr" {
                guard let attr = stringArgument(arguments, keys: ["attr", "attribute"]) else {
                    throw CLIError(message: "cmux_browser_get attr requires attr")
                }
                params["attr"] = attr
            }
            if kind == "styles",
               let property = stringArgument(arguments, keys: ["property"]) {
                params["property"] = property
            }
            return try client.sendV2(method: method, params: params)
        }
    }

    private func callEval(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let script = stringArgument(arguments, keys: ["script"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !script.isEmpty else {
            throw CLIError(message: "cmux_browser_eval requires script")
        }
        return try withClient { client in
            let surface = try resolveSurface(arguments, client: client)
            return try client.sendV2(method: "browser.eval", params: ["surface_id": surface, "script": script])
        }
    }

    private func callScreenshot(_ arguments: [String: Any]) throws -> [String: Any] {
        try withClient { client in
            let surface = try resolveSurface(arguments, client: client)
            let params: [String: Any] = ["surface_id": surface]
            var payload = try client.sendV2(method: "browser.screenshot", params: params)
            if let rawPath = stringArgument(arguments, keys: ["path", "out"]) {
                let destinationURL = URL(fileURLWithPath: cli.resolvePath(rawPath)).standardizedFileURL
                guard try persistScreenshotPayload(payload, to: destinationURL) else {
                    throw CLIError(message: "cmux_browser_screenshot missing image data")
                }
                payload["path"] = destinationURL.path
                payload["url"] = destinationURL.absoluteString
                payload.removeValue(forKey: "png_base64")
            }
            return payload
        }
    }

    private func persistScreenshotPayload(_ payload: [String: Any], to destinationURL: URL) throws -> Bool {
        if let sourcePath = payload["path"] as? String,
           hasText(sourcePath) {
            let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
            do {
                if sourceURL.path != destinationURL.path {
                    try FileManager.default.createDirectory(
                        at: destinationURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? FileManager.default.removeItem(at: destinationURL)
                    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                }
                return true
            } catch {
                if payload["png_base64"] == nil {
                    throw error
                }
            }
        }

        guard let base64 = payload["png_base64"] as? String,
              let data = Data(base64Encoded: base64) else {
            return false
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destinationURL, options: .atomic)
        return true
    }

    private func callLogList(_ arguments: [String: Any], namespace: String) throws -> [String: Any] {
        let rawAction = stringArgument(arguments, keys: ["action"]) ?? "list"
        let action = rawAction.lowercased()
        guard ["list", "clear"].contains(action) else {
            throw CLIError(message: "cmux_browser_\(namespace) action must be list or clear")
        }
        return try withClient { client in
            let surface = try resolveSurface(arguments, client: client)
            if namespace == "errors" {
                var params: [String: Any] = ["surface_id": surface]
                if action == "clear" {
                    params["clear"] = true
                }
                return try client.sendV2(method: "browser.errors.list", params: params)
            }
            return try client.sendV2(method: "browser.console.\(action)", params: ["surface_id": surface])
        }
    }

    private func callRawBrowserRPC(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let method = stringArgument(arguments, keys: ["method"]) else {
            throw CLIError(message: "cmux_browser_rpc requires method")
        }
        guard method.hasPrefix("browser.") || method == "system.identify" else {
            throw CLIError(message: "cmux_browser_rpc only allows browser.* and system.identify methods")
        }
        var params = arguments["params"] as? [String: Any] ?? [:]
        return try withClient { client in
            if let rawSurface = params["surface_id"] as? String ?? params["surface"] as? String,
               let surface = try cli.normalizeSurfaceHandle(rawSurface, client: client) {
                params["surface_id"] = surface
                params.removeValue(forKey: "surface")
                defaultSurface = surface
            }
            let timeoutMs = intArgument(arguments, key: "timeout_ms") ?? intArgument(arguments, key: "timeoutMs")
            let responseTimeout = timeoutMs.map { Double(max(1, $0)) / 1000.0 + 5.0 }
            let payload = try client.sendV2(method: method, params: params, responseTimeout: responseTimeout)
            rememberSurface(from: payload)
            return payload
        }
    }

    private func toolJSON(_ payload: [String: Any]) -> [String: Any] {
        toolText(compactJSONString(cli.formatIDs(payload, mode: .refs)))
    }

    private func toolText(_ text: String, isError: Bool = false) -> [String: Any] {
        var response: [String: Any] = [
            "content": [
                [
                    "type": "text",
                    "text": text,
                ],
            ],
        ]
        if isError {
            response["isError"] = true
        }
        return response
    }

    private func toolDefinitions() -> [[String: Any]] {
        [
            tool(
                "cmux_browser_identify",
                "Inspect cmux context and optional browser surface metadata.",
                objectSchema([
                    "surface": stringSchema("Optional browser surface handle such as surface:2 or a UUID."),
                ])
            ),
            tool(
                "cmux_browser_open",
                "Open a URL in a cmux in-app browser surface, defaulting to the caller workspace.",
                objectSchema([
                    "url": stringSchema("URL to open. Omit to open a blank browser surface."),
                    "workspace": stringSchema("Optional workspace handle."),
                    "window": stringSchema("Optional window handle."),
                    "focus": boolSchema("Whether to focus the new browser surface."),
                ])
            ),
            tool(
                "cmux_browser_navigate",
                "Navigate an existing cmux browser surface.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "url": stringSchema("URL to navigate to."),
                    "snapshot_after": boolSchema("Return a post-navigation snapshot when supported."),
                ], required: ["url"])
            ),
            tool(
                "cmux_browser_snapshot",
                "Capture the page accessibility-style snapshot. Interactive refs are enabled by default.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "interactive": boolSchema("Whether to include interactive refs. Defaults to true."),
                    "compact": boolSchema("Use compact snapshot formatting."),
                    "cursor": boolSchema("Include cursor information when supported."),
                    "selector": stringSchema("Optional CSS selector root."),
                    "max_depth": intSchema("Optional maximum tree depth."),
                ])
            ),
            tool(
                "cmux_browser_click",
                "Click a selector or interactive snapshot ref in a cmux browser surface.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "selector": stringSchema("CSS selector or interactive ref, such as e3."),
                    "snapshot_after": boolSchema("Return a post-action snapshot when supported."),
                ], required: ["selector"])
            ),
            tool(
                "cmux_browser_fill",
                "Set an input value. Passing an empty text string clears the input.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "selector": stringSchema("CSS selector or interactive ref."),
                    "text": stringSchema("Text to set."),
                    "snapshot_after": boolSchema("Return a post-action snapshot when supported."),
                ], required: ["selector", "text"])
            ),
            tool(
                "cmux_browser_type",
                "Type text into an input or focused element.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "selector": stringSchema("CSS selector or interactive ref."),
                    "text": stringSchema("Text to type."),
                    "snapshot_after": boolSchema("Return a post-action snapshot when supported."),
                ], required: ["selector", "text"])
            ),
            tool(
                "cmux_browser_wait",
                "Wait for selector, text, URL, load state, or JavaScript condition.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "selector": stringSchema("CSS selector to wait for."),
                    "text": stringSchema("Text to wait for."),
                    "text_contains": stringSchema("Text to wait for."),
                    "url_contains": stringSchema("URL substring to wait for."),
                    "load_state": stringSchema("Load state such as interactive or complete."),
                    "function": stringSchema("JavaScript predicate expression."),
                    "timeout_ms": intSchema("Timeout in milliseconds."),
                ])
            ),
            tool(
                "cmux_browser_get",
                "Read URL, title, text, HTML, value, attr, count, box, or styles from a page.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "kind": enumSchema(["url", "title", "text", "html", "value", "attr", "count", "box", "styles"]),
                    "selector": stringSchema("CSS selector or interactive ref for DOM reads."),
                    "attr": stringSchema("Attribute name for kind=attr."),
                    "property": stringSchema("CSS property for kind=styles."),
                ], required: ["kind"])
            ),
            tool(
                "cmux_browser_eval",
                "Evaluate JavaScript in the cmux browser surface.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "script": stringSchema("JavaScript expression or script."),
                ], required: ["script"])
            ),
            tool(
                "cmux_browser_screenshot",
                "Capture a screenshot from the cmux browser surface.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "path": stringSchema("Optional output path."),
                    "out": stringSchema("Optional output path alias."),
                ])
            ),
            tool(
                "cmux_browser_console",
                "List or clear captured console messages for a cmux browser surface.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "action": enumSchema(["list", "clear"]),
                ])
            ),
            tool(
                "cmux_browser_errors",
                "List or clear captured page errors for a cmux browser surface.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "action": enumSchema(["list", "clear"]),
                ])
            ),
            tool(
                "cmux_browser_rpc",
                "Call a raw cmux browser.* socket method for advanced workflows.",
                objectSchema([
                    "method": stringSchema("Allowed method name: browser.* or system.identify."),
                    "params": [
                        "type": "object",
                        "description": "Method parameters.",
                        "additionalProperties": true,
                    ],
                    "timeout_ms": intSchema("Optional response timeout in milliseconds."),
                ], required: ["method"])
            ),
        ]
    }

    private func tool(_ name: String, _ description: String, _ inputSchema: [String: Any]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
        ]
    }

    private func objectSchema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false,
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }

    private func stringSchema(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private func boolSchema(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    private func intSchema(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    private func enumSchema(_ values: [String]) -> [String: Any] {
        ["type": "string", "enum": values]
    }

    private func stringArgument(_ arguments: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = arguments[key] as? String {
                return value
            }
            if let value = arguments[key] as? NSNumber {
                return value.stringValue
            }
        }
        return nil
    }

    private func boolArgument(_ arguments: [String: Any], key: String) -> Bool? {
        cli.boolFromAny(arguments[key])
    }

    private func intArgument(_ arguments: [String: Any], key: String) -> Int? {
        cli.intFromAny(arguments[key])
    }

    private func copyString(_ arguments: [String: Any], from sourceKey: String, to destinationKey: String, into params: inout [String: Any]) {
        if let value = stringArgument(arguments, keys: [sourceKey]) {
            params[destinationKey] = value
        }
    }

    private func hasText(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func writeResponse(id: Any?, result: Any) {
        writeJSON([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result,
        ])
    }

    private func writeError(id: Any?, code: Int, message: String) {
        writeJSON([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": code,
                "message": message,
            ],
        ])
    }

    private func writeJSON(_ object: Any) {
        let line = compactJSONString(object) + "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    private func writeStderr(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }

    private func compactJSONString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let output = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return output
    }

    private static func versionString() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let shortVersion = (info["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let build = (info["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let shortVersion,
           !shortVersion.isEmpty,
           !shortVersion.contains("$("),
           let build,
           !build.isEmpty,
           !build.contains("$(") {
            return "\(shortVersion)+\(build)"
        }
        return "unknown"
    }
}
