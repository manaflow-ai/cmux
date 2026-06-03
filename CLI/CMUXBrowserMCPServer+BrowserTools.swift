import Foundation

extension CMUXBrowserMCPServer {
    func withClient<T>(_ body: (SocketClient) throws -> T) throws -> T {
        let client = try cli.connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: false
        )
        defer { client.close() }
        return try body(client)
    }

    func resolveSurface(_ arguments: [String: Any], client: SocketClient) throws -> String {
        let raw = stringArgument(arguments, keys: ["surface", "surface_id"]) ??
            defaultSurface ??
            ProcessInfo.processInfo.environment["CMUX_BROWSER_SURFACE_ID"]
        guard let raw,
              let surface = try cli.normalizeSurfaceHandle(raw, client: client) else {
            throw CLIError(
                message: String(
                    localized: "cli.browserMCP.error.surfaceRequired",
                    defaultValue: "A browser surface is required. Call cmux_browser_open first or pass surface."
                )
            )
        }
        defaultSurface = surface
        return surface
    }

    func rememberSurface(from payload: [String: Any]) {
        if let surface = payload["surface_id"] as? String ?? payload["surface_ref"] as? String {
            defaultSurface = surface
        } else if let surface = payload["surface"] as? String {
            defaultSurface = surface
        }
    }

    func callIdentify(_ arguments: [String: Any]) throws -> [String: Any] {
        try withClient { client in
            let surfaceRaw = stringArgument(arguments, keys: ["surface", "surface_id"])
            let requestedSurface: String?
            if let surfaceRaw {
                guard let surface = try cli.normalizeSurfaceHandle(surfaceRaw, client: client) else {
                    throw CLIError(
                        message: String(
                            localized: "cli.browserMCP.error.invalidSurfaceHandle",
                            defaultValue: "Invalid browser surface handle"
                        )
                    )
                }
                requestedSurface = surface
            } else {
                requestedSurface = nil
            }

            var payload = try client.sendV2(method: "system.identify")
            if let surface = requestedSurface {
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

    func callOpen(_ arguments: [String: Any]) throws -> [String: Any] {
        try withClient { client in
            var params: [String: Any] = [:]
            if let url = stringArgument(arguments, keys: ["url"]) {
                params["url"] = url
            }
            let workspaceRaw = stringArgument(arguments, keys: ["workspace", "workspace_id"])
            let windowRaw = stringArgument(arguments, keys: ["window", "window_id"])
            if let workspaceRaw {
                guard let workspace = try cli.normalizeWorkspaceHandle(workspaceRaw, client: client) else {
                    throw CLIError(
                        message: String(
                            localized: "cli.browserMCP.error.invalidWorkspaceHandle",
                            defaultValue: "Invalid workspace handle"
                        )
                    )
                }
                params["workspace_id"] = workspace
            } else if windowRaw == nil,
                      let environmentWorkspaceRaw = ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"],
                      let workspace = try cli.normalizeWorkspaceHandle(environmentWorkspaceRaw, client: client) {
                params["workspace_id"] = workspace
            }
            if let windowRaw {
                guard let window = try cli.normalizeWindowHandle(windowRaw, client: client) else {
                    throw CLIError(
                        message: String(
                            localized: "cli.browserMCP.error.invalidWindowHandle",
                            defaultValue: "Invalid window handle"
                        )
                    )
                }
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

    func callNavigate(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let url = stringArgument(arguments, keys: ["url"]) else {
            throw CLIError(
                message: String(
                    localized: "cli.browserMCP.error.navigateURLRequired",
                    defaultValue: "cmux_browser_navigate requires url"
                )
            )
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

    func callSnapshot(_ arguments: [String: Any]) throws -> [String: Any] {
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

    func callSimpleSelector(_ arguments: [String: Any], method: String, label: String) throws -> [String: Any] {
        guard let selector = stringArgument(arguments, keys: ["selector", "ref"]) else {
            throw CLIError(
                message: String(
                    localized: "cli.browserMCP.error.selectorRequired",
                    defaultValue: "cmux_browser_\(label) requires selector"
                )
            )
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

    func callTextInput(
        _ arguments: [String: Any],
        method: String,
        label: String,
        allowEmptyText: Bool
    ) throws -> [String: Any] {
        guard let selector = stringArgument(arguments, keys: ["selector", "ref"]) else {
            throw CLIError(
                message: String(
                    localized: "cli.browserMCP.error.selectorRequired",
                    defaultValue: "cmux_browser_\(label) requires selector"
                )
            )
        }
        guard let text = stringArgument(arguments, keys: ["text"]),
              allowEmptyText || !text.isEmpty else {
            throw CLIError(
                message: String(
                    localized: "cli.browserMCP.error.textRequired",
                    defaultValue: "cmux_browser_\(label) requires text"
                )
            )
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

    func callWait(_ arguments: [String: Any]) throws -> [String: Any] {
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

    func callGet(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let rawKind = stringArgument(arguments, keys: ["kind", "target"]) else {
            throw CLIError(
                message: String(localized: "cli.browserMCP.error.getKindRequired", defaultValue: "cmux_browser_get requires kind")
            )
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
            throw CLIError(
                message: String(
                    localized: "cli.browserMCP.error.unsupportedGetKind",
                    defaultValue: "Unsupported cmux_browser_get kind: \(kind)"
                )
            )
        }
        return try withClient { client in
            let surface = try resolveSurface(arguments, client: client)
            var params: [String: Any] = ["surface_id": surface]
            if !["url", "title"].contains(kind) {
                guard let selector = stringArgument(arguments, keys: ["selector", "ref"]) else {
                    throw CLIError(
                        message: String(
                            localized: "cli.browserMCP.error.getSelectorRequired",
                            defaultValue: "cmux_browser_get kind \(kind) requires selector"
                        )
                    )
                }
                params["selector"] = selector
            }
            if kind == "attr" {
                guard let attr = stringArgument(arguments, keys: ["attr", "attribute"]) else {
                    throw CLIError(
                        message: String(localized: "cli.browserMCP.error.getAttrRequired", defaultValue: "cmux_browser_get attr requires attr")
                    )
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

    func callEval(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let script = stringArgument(arguments, keys: ["script"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !script.isEmpty else {
            throw CLIError(
                message: String(localized: "cli.browserMCP.error.evalScriptRequired", defaultValue: "cmux_browser_eval requires script")
            )
        }
        return try withClient { client in
            let surface = try resolveSurface(arguments, client: client)
            return try client.sendV2(method: "browser.eval", params: ["surface_id": surface, "script": script])
        }
    }

    func callScreenshot(_ arguments: [String: Any]) throws -> [String: Any] {
        try withClient { client in
            let surface = try resolveSurface(arguments, client: client)
            let params: [String: Any] = ["surface_id": surface]
            var payload = try client.sendV2(method: "browser.screenshot", params: params)
            if let rawPath = stringArgument(arguments, keys: ["path", "out"]) {
                let destinationURL = URL(fileURLWithPath: cli.resolvePath(rawPath)).standardizedFileURL
                guard try persistScreenshotPayload(payload, to: destinationURL) else {
                    throw CLIError(
                        message: String(
                            localized: "cli.browserMCP.error.screenshotMissingImageData",
                            defaultValue: "cmux_browser_screenshot missing image data"
                        )
                    )
                }
                payload["path"] = destinationURL.path
                payload["url"] = destinationURL.absoluteString
                payload.removeValue(forKey: "png_base64")
            }
            return payload
        }
    }

    func persistScreenshotPayload(_ payload: [String: Any], to destinationURL: URL) throws -> Bool {
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

    func callLogList(_ arguments: [String: Any], namespace: String) throws -> [String: Any] {
        let rawAction = stringArgument(arguments, keys: ["action"]) ?? "list"
        let action = rawAction.lowercased()
        guard ["list", "clear"].contains(action) else {
            throw CLIError(
                message: String(
                    localized: "cli.browserMCP.error.logActionInvalid",
                    defaultValue: "cmux_browser_\(namespace) action must be list or clear"
                )
            )
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

    func callRawBrowserRPC(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let method = stringArgument(arguments, keys: ["method"]) else {
            throw CLIError(
                message: String(localized: "cli.browserMCP.error.rpcMethodRequired", defaultValue: "cmux_browser_rpc requires method")
            )
        }
        guard method.hasPrefix("browser.") || method == "system.identify" else {
            throw CLIError(
                message: String(
                    localized: "cli.browserMCP.error.rpcMethodNotAllowed",
                    defaultValue: "cmux_browser_rpc only allows browser.* and system.identify methods"
                )
            )
        }
        let paramsObject: [String: Any]
        if let paramsValue = arguments["params"] {
            guard let object = paramsValue as? [String: Any] else {
                throw CLIError(
                    message: String(localized: "cli.browserMCP.error.invalidRequest", defaultValue: "Invalid Request")
                )
            }
            paramsObject = object
        } else {
            paramsObject = [:]
        }
        var params = paramsObject
        return try withClient { client in
            if let rawSurfaceValue = params["surface_id"] ?? params["surface"] {
                guard let rawSurface = rawSurfaceValue as? String,
                      let surface = try cli.normalizeSurfaceHandle(rawSurface, client: client) else {
                    throw CLIError(
                        message: String(
                            localized: "cli.browserMCP.error.invalidSurfaceHandle",
                            defaultValue: "Invalid browser surface handle"
                        )
                    )
                }
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
}
