import Foundation

// MARK: - MCP Content-Length Framing

/// Parses MCP Content-Length framed messages from raw bytes.
/// Format: `Content-Length: N\r\n\r\n{json of N bytes}`
enum MCPFraming {
    /// Result of attempting to parse one MCP message from a buffer.
    enum ParseResult {
        /// Successfully parsed a message; `consumed` is the total bytes eaten from the buffer.
        case message(Data, consumed: Int)
        /// Not enough data yet — need more bytes.
        case needMore
        /// Buffer does not start with "Content-Length:" — not MCP.
        case notMCP
    }

    /// Try to extract one Content-Length framed message from the front of `buffer`.
    static func parse(_ buffer: Data) -> ParseResult {
        // MCP header starts with "Content-Length: "
        let headerPrefix = "Content-Length: ".data(using: .utf8)!
        guard buffer.count >= headerPrefix.count else {
            // Could still be MCP if we haven't received enough bytes.
            // Check if what we have is a prefix of "Content-Length: ".
            if buffer.count > 0 {
                let partial = headerPrefix.prefix(buffer.count)
                if buffer.starts(with: partial) {
                    return .needMore
                }
            }
            return buffer.isEmpty ? .needMore : .notMCP
        }

        guard buffer.starts(with: headerPrefix) else {
            return .notMCP
        }

        // Find \r\n\r\n separator
        let separator = "\r\n\r\n".data(using: .utf8)!
        guard let separatorRange = buffer.range(of: separator) else {
            return .needMore
        }

        // Extract content length value
        let headerEnd = separatorRange.lowerBound
        let headerData = buffer[headerPrefix.count..<headerEnd]
        guard let headerStr = String(data: headerData, encoding: .utf8),
              let contentLength = Int(headerStr.trimmingCharacters(in: .whitespaces)),
              contentLength >= 0 else {
            return .notMCP
        }

        // Check if we have the full body
        let bodyStart = separatorRange.upperBound
        let totalNeeded = bodyStart + contentLength
        guard buffer.count >= totalNeeded else {
            return .needMore
        }

        let body = buffer[bodyStart..<(bodyStart + contentLength)]
        return .message(Data(body), consumed: totalNeeded)
    }

    /// Encode a JSON response with Content-Length framing.
    static func encode(_ json: Data) -> Data {
        let header = "Content-Length: \(json.count)\r\n\r\n"
        var result = header.data(using: .utf8)!
        result.append(json)
        return result
    }

    /// Encode a dictionary as a JSON-RPC response with Content-Length framing.
    static func encodeResponse(_ dict: [String: Any]) -> Data {
        guard let json = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            // Fallback: return a minimal JSON-RPC error that is always serializable
            let fallback = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal serialization error"}}"#
            return encode(fallback.data(using: .utf8)!)
        }
        return encode(json)
    }
}

// MARK: - MCP JSON-RPC Protocol

/// Handles MCP JSON-RPC 2.0 protocol methods.
/// Routes `initialize`, `tools/list`, `tools/call` and delegates tool execution.
final class MCPHandler {
    /// Callback to execute a cmux V2 method. Returns the V2 result dict or throws.
    typealias V2Executor = (_ method: String, _ params: [String: Any]) -> V2ExecutorResult

    enum V2ExecutorResult {
        case ok(Any)
        case error(code: String, message: String)
    }

    private let v2Execute: V2Executor
    private var initialized = false

    init(v2Execute: @escaping V2Executor) {
        self.v2Execute = v2Execute
    }

    /// Process one MCP JSON-RPC request. Returns the response dict.
    func handleRequest(_ data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return jsonRPCError(id: NSNull(), code: -32700, message: "Parse error")
        }

        let id: Any = object["id"] ?? NSNull()
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any] ?? [:]

        // Notifications (no id) — acknowledge silently
        if object["id"] == nil {
            return nil
        }

        switch method {
        case "initialize":
            return handleInitialize(id: id, params: params)
        case "initialized":
            // Client notification — no response needed
            return nil
        case "ping":
            return jsonRPCResult(id: id, result: [:])
        case "tools/list", "tools/call":
            // Require initialize handshake before tool operations
            guard initialized else {
                return jsonRPCError(id: id, code: -32002, message: "Server not initialized. Send initialize first.")
            }
            if method == "tools/list" {
                return handleToolsList(id: id, params: params)
            } else {
                return handleToolsCall(id: id, params: params)
            }
        default:
            return jsonRPCError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - MCP Methods

    private func handleInitialize(id: Any, params: [String: Any]) -> [String: Any] {
        initialized = true
        return jsonRPCResult(id: id, result: [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": [
                    "listChanged": false
                ]
            ],
            "serverInfo": [
                "name": "cmux",
                "version": "0.1.0"
            ]
        ])
    }

    private func handleToolsList(id: Any, params: [String: Any]) -> [String: Any] {
        return jsonRPCResult(id: id, result: [
            "tools": MCPToolSchemas.all
        ])
    }

    private func handleToolsCall(id: Any, params: [String: Any]) -> [String: Any] {
        guard let toolName = params["name"] as? String else {
            return jsonRPCError(id: id, code: -32602, message: "Missing tool name")
        }

        let toolArgs = params["arguments"] as? [String: Any] ?? [:]

        guard let route = MCPToolSchemas.route(for: toolName) else {
            return jsonRPCError(id: id, code: -32602, message: "Unknown tool: \(toolName)")
        }

        // Map MCP tool arguments to V2 method params
        let v2Params = route.mapParams(toolArgs)
        let result = v2Execute(route.v2Method, v2Params)

        switch result {
        case .ok(let payload):
            let text: String
            if let dict = payload as? [String: Any],
               let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: []),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                text = jsonStr
            } else {
                text = String(describing: payload)
            }
            return jsonRPCResult(id: id, result: [
                "content": [
                    ["type": "text", "text": text]
                ]
            ])
        case .error(_, let message):
            return jsonRPCResult(id: id, result: [
                "content": [
                    ["type": "text", "text": "Error: \(message)"]
                ],
                "isError": true
            ])
        }
    }

    // MARK: - JSON-RPC Helpers

    private func jsonRPCResult(id: Any, result: [String: Any]) -> [String: Any] {
        return [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]
    }

    private func jsonRPCError(id: Any, code: Int, message: String) -> [String: Any] {
        return [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ]
    }
}

// MARK: - MCP Tool Schemas & Routing

/// Defines the 20 MCP tools and their mapping to V2 methods.
enum MCPToolSchemas {
    struct Route {
        let v2Method: String
        let mapParams: ([String: Any]) -> [String: Any]
    }

    /// All tool schemas for tools/list response.
    static let all: [[String: Any]] = [
        tool("list_surfaces",
             description: "List all surfaces (terminal/browser panes) across workspaces",
             properties: [
                "workspace": prop("string", "Filter by workspace ref")
             ]),
        tool("read_screen",
             description: "Read the current screen content of a terminal surface",
             properties: [
                "surface": prop("string", "Target surface ref"),
                "lines": prop("integer", "Number of lines to read (default 20)"),
                "scrollback": prop("boolean", "Include scrollback buffer")
             ],
             required: ["surface"]),
        tool("send_input",
             description: "Send text input to a terminal surface",
             properties: [
                "surface": prop("string", "Target surface ref"),
                "text": prop("string", "Text to send"),
                "workspace": prop("string", "Target workspace ref"),
                "press_enter": prop("boolean", "Press enter after sending")
             ],
             required: ["surface", "text"]),
        tool("send_key",
             description: "Send a key press to a terminal surface",
             properties: [
                "surface": prop("string", "Target surface ref"),
                "key": prop("string", "Key name (e.g. 'return', 'escape', 'tab')"),
                "workspace": prop("string", "Target workspace ref")
             ],
             required: ["surface", "key"]),
        tool("new_split",
             description: "Create a new split pane (terminal or browser)",
             properties: [
                "direction": propEnum("string", "Split direction", ["left", "right", "up", "down"]),
                "workspace": prop("string", "Target workspace ref"),
                "surface": prop("string", "Target surface ref"),
                "pane": prop("string", "Target pane ref"),
                "type": propEnum("string", "Surface type", ["terminal", "browser"]),
                "url": prop("string", "URL for browser surfaces"),
                "title": prop("string", "Tab title"),
                "focus": prop("boolean", "Focus the new pane (default true)")
             ],
             required: ["direction"]),
        tool("close_surface",
             description: "Close a surface (terminal or browser pane)",
             properties: [
                "surface": prop("string", "Target surface ref"),
                "workspace": prop("string", "Target workspace ref")
             ],
             required: ["surface"]),
        tool("set_status",
             description: "Set a sidebar status key-value pair",
             properties: [
                "key": prop("string", "Status key"),
                "value": prop("string", "Status value"),
                "workspace": prop("string", "Target workspace ref"),
                "surface": prop("string", "Target surface ref"),
                "icon": prop("string", "Icon name"),
                "color": prop("string", "Hex color (#RRGGBB)")
             ],
             required: ["key", "value"]),
        tool("set_progress",
             description: "Set sidebar progress indicator (0.0 to 1.0)",
             properties: [
                "value": prop("number", "Progress value between 0 and 1"),
                "label": prop("string", "Progress label text"),
                "workspace": prop("string", "Target workspace ref"),
                "surface": prop("string", "Target surface ref")
             ],
             required: ["value"]),
        tool("rename_tab",
             description: "Rename a surface tab",
             properties: [
                "surface": prop("string", "Target surface ref"),
                "title": prop("string", "New tab title"),
                "workspace": prop("string", "Target workspace ref")
             ],
             required: ["surface", "title"]),
        tool("list_workspaces",
             description: "List all workspaces",
             properties: [:]),
        tool("create_workspace",
             description: "Create a new workspace",
             properties: [
                "title": prop("string", "Workspace title"),
                "select": prop("boolean", "Select the new workspace (default true)")
             ]),
        tool("select_workspace",
             description: "Select (switch to) a workspace",
             properties: [
                "workspace": prop("string", "Target workspace ref")
             ],
             required: ["workspace"]),
        tool("list_panes",
             description: "List all panes in a workspace",
             properties: [
                "workspace": prop("string", "Target workspace ref")
             ]),
        tool("focus_pane",
             description: "Focus a specific pane",
             properties: [
                "pane": prop("string", "Target pane ref"),
                "workspace": prop("string", "Target workspace ref")
             ],
             required: ["pane"]),
        tool("system_identify",
             description: "Get currently focused workspace, pane, and surface",
             properties: [:]),
        tool("system_tree",
             description: "Get full window/workspace/pane/surface tree",
             properties: [:]),
        tool("notification_create",
             description: "Create a notification",
             properties: [
                "title": prop("string", "Notification title"),
                "body": prop("string", "Notification body"),
                "surface": prop("string", "Target surface ref"),
                "workspace": prop("string", "Target workspace ref")
             ],
             required: ["title"]),
        tool("browser_open",
             description: "Open a browser pane",
             properties: [
                "url": prop("string", "URL to open"),
                "workspace": prop("string", "Target workspace ref"),
                "direction": propEnum("string", "Split direction", ["left", "right", "up", "down"])
             ]),
        tool("browser_navigate",
             description: "Navigate a browser surface to a URL",
             properties: [
                "surface": prop("string", "Target browser surface ref"),
                "url": prop("string", "URL to navigate to")
             ],
             required: ["surface", "url"]),
        tool("browser_snapshot",
             description: "Take an accessibility snapshot of a browser surface",
             properties: [
                "surface": prop("string", "Target browser surface ref")
             ],
             required: ["surface"]),
    ]

    // MARK: - Tool Routing

    private static let routes: [String: Route] = [
        "list_surfaces": Route(v2Method: "surface.list", mapParams: { params in
            var v2: [String: Any] = [:]
            if let ws = params["workspace"] { v2["workspace"] = ws }
            return v2
        }),
        "read_screen": Route(v2Method: "surface.read_text", mapParams: { params in
            var v2: [String: Any] = [:]
            if let s = params["surface"] { v2["surface"] = s }
            if let l = params["lines"] { v2["lines"] = l }
            if let sb = params["scrollback"] { v2["scrollback"] = sb }
            if let ws = params["workspace"] { v2["workspace"] = ws }
            return v2
        }),
        "send_input": Route(v2Method: "surface.send_text", mapParams: { params in
            var v2: [String: Any] = [:]
            if let s = params["surface"] { v2["surface"] = s }
            if let t = params["text"] { v2["text"] = t }
            if let ws = params["workspace"] { v2["workspace"] = ws }
            if let pe = params["press_enter"] { v2["press_enter"] = pe }
            return v2
        }),
        "send_key": Route(v2Method: "surface.send_key", mapParams: { params in
            var v2: [String: Any] = [:]
            if let s = params["surface"] { v2["surface"] = s }
            if let k = params["key"] { v2["key"] = k }
            if let ws = params["workspace"] { v2["workspace"] = ws }
            return v2
        }),
        "new_split": Route(v2Method: "surface.split", mapParams: { params in
            var v2: [String: Any] = [:]
            if let d = params["direction"] { v2["direction"] = d }
            if let ws = params["workspace"] { v2["workspace"] = ws }
            if let s = params["surface"] { v2["surface"] = s }
            if let p = params["pane"] { v2["pane"] = p }
            if let t = params["type"] { v2["type"] = t }
            if let u = params["url"] { v2["url"] = u }
            if let ti = params["title"] { v2["title"] = ti }
            if let f = params["focus"] { v2["focus"] = f }
            return v2
        }),
        "close_surface": Route(v2Method: "surface.close", mapParams: { params in
            var v2: [String: Any] = [:]
            if let s = params["surface"] { v2["surface"] = s }
            if let ws = params["workspace"] { v2["workspace"] = ws }
            return v2
        }),
        "set_status": Route(v2Method: "report_meta", mapParams: { params in
            // V1 command: set_status key value
            // This maps to V1 sidebar commands, handled specially
            return params
        }),
        "set_progress": Route(v2Method: "set_progress", mapParams: { params in
            return params
        }),
        "rename_tab": Route(v2Method: "surface.action", mapParams: { params in
            var v2: [String: Any] = [:]
            if let s = params["surface"] { v2["surface"] = s }
            if let t = params["title"] { v2["title"] = t }
            v2["action"] = "rename"
            if let ws = params["workspace"] { v2["workspace"] = ws }
            return v2
        }),
        "list_workspaces": Route(v2Method: "workspace.list", mapParams: { _ in [:] }),
        "create_workspace": Route(v2Method: "workspace.create", mapParams: { params in
            var v2: [String: Any] = [:]
            if let t = params["title"] { v2["title"] = t }
            if let s = params["select"] { v2["select"] = s }
            return v2
        }),
        "select_workspace": Route(v2Method: "workspace.select", mapParams: { params in
            var v2: [String: Any] = [:]
            if let ws = params["workspace"] { v2["workspace"] = ws }
            return v2
        }),
        "list_panes": Route(v2Method: "pane.list", mapParams: { params in
            var v2: [String: Any] = [:]
            if let ws = params["workspace"] { v2["workspace"] = ws }
            return v2
        }),
        "focus_pane": Route(v2Method: "pane.focus", mapParams: { params in
            var v2: [String: Any] = [:]
            if let p = params["pane"] { v2["pane"] = p }
            if let ws = params["workspace"] { v2["workspace"] = ws }
            return v2
        }),
        "system_identify": Route(v2Method: "system.identify", mapParams: { _ in [:] }),
        "system_tree": Route(v2Method: "system.tree", mapParams: { _ in [:] }),
        "notification_create": Route(v2Method: "notification.create", mapParams: { params in
            var v2: [String: Any] = [:]
            if let t = params["title"] { v2["title"] = t }
            if let b = params["body"] { v2["body"] = b }
            if let s = params["surface"] { v2["surface"] = s }
            if let ws = params["workspace"] { v2["workspace"] = ws }
            return v2
        }),
        "browser_open": Route(v2Method: "browser.open_split", mapParams: { params in
            var v2: [String: Any] = [:]
            if let u = params["url"] { v2["url"] = u }
            if let ws = params["workspace"] { v2["workspace"] = ws }
            if let d = params["direction"] { v2["direction"] = d }
            return v2
        }),
        "browser_navigate": Route(v2Method: "browser.navigate", mapParams: { params in
            var v2: [String: Any] = [:]
            if let s = params["surface"] { v2["surface"] = s }
            if let u = params["url"] { v2["url"] = u }
            return v2
        }),
        "browser_snapshot": Route(v2Method: "browser.snapshot", mapParams: { params in
            var v2: [String: Any] = [:]
            if let s = params["surface"] { v2["surface"] = s }
            return v2
        }),
    ]

    static func route(for toolName: String) -> Route? {
        return routes[toolName]
    }

    // MARK: - Schema Helpers

    private static func tool(
        _ name: String,
        description: String,
        properties: [String: [String: Any]],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return [
            "name": name,
            "description": description,
            "inputSchema": schema
        ]
    }

    private static func prop(_ type: String, _ description: String) -> [String: Any] {
        return ["type": type, "description": description]
    }

    private static func propEnum(_ type: String, _ description: String, _ values: [String]) -> [String: Any] {
        return ["type": type, "description": description, "enum": values]
    }
}
