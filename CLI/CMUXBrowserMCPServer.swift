import Foundation

private struct CMUXBrowserMCPParseError: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

final class CMUXBrowserMCPServer {
    static let protocolVersion = "2025-06-18"

    let cli: CMUXCLI
    let socketPath: String
    let explicitPassword: String?
    var defaultSurface: String?

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
                let message = sanitizedErrorMessage(error)
                logDiagnostic("cmux browser MCP failed to process a message: \(message)")
                writeError(id: nil, code: jsonRPCErrorCode(for: error), message: message)
            }
        }
    }

    func jsonRPCErrorCode(for error: Error) -> Int {
        if error is CMUXBrowserMCPParseError {
            return -32700
        }
        return error is CLIError ? -32600 : -32700
    }

    func handleMessageLine(_ line: String) throws {
        guard let data = line.data(using: .utf8) else {
            throw CMUXBrowserMCPParseError(
                message: String(localized: "cli.browserMCP.error.invalidUTF8", defaultValue: "Invalid UTF-8 MCP message")
            )
        }
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        if let batch = object as? [Any] {
            guard !batch.isEmpty else {
                writeError(
                    id: nil,
                    code: -32600,
                    message: String(localized: "cli.browserMCP.error.invalidMessage", defaultValue: "Invalid MCP message")
                )
                return
            }
            var responses: [[String: Any]] = []
            for element in batch {
                guard let message = element as? [String: Any] else {
                    responses.append(errorObject(
                        id: nil,
                        code: -32600,
                        message: String(localized: "cli.browserMCP.error.invalidMessage", defaultValue: "Invalid MCP message")
                    ))
                    continue
                }
                if let response = handleMessageResponse(message) {
                    responses.append(response)
                }
            }
            if !responses.isEmpty {
                writeJSON(responses)
            }
            return
        }
        guard let message = object as? [String: Any] else {
            throw CLIError(
                message: String(localized: "cli.browserMCP.error.invalidMessage", defaultValue: "Invalid MCP message")
            )
        }
        handleMessage(message)
    }

    func handleMessage(_ message: [String: Any]) {
        if let response = handleMessageResponse(message) {
            writeJSON(response)
        }
    }

    func handleMessageResponse(_ message: [String: Any]) -> [String: Any]? {
        let hasID = message.keys.contains("id")
        let rawID = message["id"]
        guard isValidJSONRPCID(rawID, hasID: hasID) else {
            return errorObject(
                id: nil,
                code: -32600,
                message: String(localized: "cli.browserMCP.error.invalidRequest", defaultValue: "Invalid Request")
            )
        }
        let id = rawID
        if !hasID {
            guard message["jsonrpc"] as? String == "2.0",
                  let method = message["method"] as? String else {
                logDiagnostic("cmux browser MCP ignored invalid notification")
                return nil
            }
            handleNotification(method: method)
            return nil
        }

        guard message["jsonrpc"] as? String == "2.0" else {
            return errorObject(
                id: id,
                code: -32600,
                message: String(
                    localized: "cli.browserMCP.error.invalidJSONRPCVersion",
                    defaultValue: "Invalid Request: jsonrpc must be \"2.0\""
                )
            )
        }
        guard let method = message["method"] as? String else {
            return errorObject(
                id: id,
                code: -32600,
                message: String(localized: "cli.browserMCP.error.invalidRequest", defaultValue: "Invalid Request")
            )
        }

        do {
            let result: Any
            switch method {
            case "initialize":
                result = initializeResult()
            case "ping":
                result = [:] as [String: Any]
            case "tools/list":
                result = ["tools": toolDefinitions()]
            case "tools/call":
                do {
                    result = try handleToolCall(params: message["params"] as? [String: Any])
                } catch let error as CLIError {
                    return errorObject(id: id, code: -32602, message: sanitizedErrorMessage(error))
                }
            default:
                return errorObject(
                    id: id,
                    code: -32601,
                    message: String(
                        localized: "cli.browserMCP.error.methodNotFound",
                        defaultValue: "Method not found: \(method)"
                    )
                )
            }
            return responseObject(id: id, result: result)
        } catch {
            return errorObject(id: id, code: -32603, message: sanitizedErrorMessage(error))
        }
    }

    func isValidJSONRPCID(_ rawID: Any?, hasID: Bool) -> Bool {
        guard hasID else { return true }
        guard let rawID else { return true }
        switch rawID {
        case is NSNull, is String:
            return true
        case let number as NSNumber:
            return CFGetTypeID(number) != CFBooleanGetTypeID()
        default:
            return false
        }
    }

    func handleNotification(method: String) {
        if method != "notifications/initialized" {
            logDiagnostic("cmux browser MCP ignored notification: \(method)")
        }
    }

    func initializeResult() -> [String: Any] {
        [
            "protocolVersion": Self.protocolVersion,
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

    func handleToolCall(params: [String: Any]?) throws -> [String: Any] {
        guard let params,
              let name = params["name"] as? String else {
            throw CLIError(
                message: String(
                    localized: "cli.browserMCP.error.toolNameRequired",
                    defaultValue: "tools/call requires a tool name"
                )
            )
        }
        let arguments: [String: Any]
        if let argumentsValue = params["arguments"] {
            guard let argumentsObject = argumentsValue as? [String: Any] else {
                throw CLIError(
                    message: String(localized: "cli.browserMCP.error.invalidRequest", defaultValue: "Invalid Request")
                )
            }
            arguments = argumentsObject
        } else {
            arguments = [:]
        }
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
                throw CLIError(
                    message: String(
                        localized: "cli.browserMCP.error.unknownTool",
                        defaultValue: "Unknown cmux browser MCP tool: \(name)"
                    )
                )
            }
        } catch {
            return toolText(sanitizedErrorMessage(error), isError: true)
        }
    }
}
