import Foundation

nonisolated public enum SocketCommandExecutionPolicy: Equatable {
    case mainActor
    case socketWorker
}

// Parsed socket requests are immutable snapshots moved into socket-worker tasks.
nonisolated public struct V2SocketRequest: @unchecked Sendable {
    public let id: Any?
    public let method: String
    public let params: [String: Any]
    public let usesJSONRPC: Bool
    public let hasIdMember: Bool
}

nonisolated public enum V2SocketRequestParseError: Error, Equatable {
    case missingMethod
    case invalidParams
    case malformedID
    case invalidJSONRPCVersion
}

nonisolated public enum V2CallResult {
    case ok(Any)
    case err(code: String, message: String, data: Any?)
}

nonisolated public enum CMUXSocketProtocol {
    public static let invalidDispatchMessage =
        String(
            localized: "socket.error.invalidDispatch",
            defaultValue: "cmux cannot perform this request in the current socket context. Perform it asynchronously and retry."
        )

    public static func usesJSONRPC(_ dict: [String: Any]) -> Bool {
        (dict["jsonrpc"] as? String) == "2.0"
    }

    public static func malformedRequestUsesJSONRPC(_ command: String) -> Bool {
        if let data = command.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: []) {
            if let dict = object as? [String: Any] {
                return usesJSONRPC(dict)
            }
            if let array = object as? [Any], array.count >= 2 {
                return (array[0] as? String) == "jsonrpc" && (array[1] as? String) == "2.0"
            }
        }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return topLevelObjectDeclaresJSONRPC2(trimmed) || topLevelArrayDeclaresJSONRPC2(trimmed)
    }

    public static func malformedRequestError(command: String, code: String, message: String) -> String {
        if malformedRequestUsesJSONRPC(command) {
            return error(id: nil, jsonRPC: true, code: code, message: message)
        }
        return encode([
            "ok": false,
            "error": ["code": code, "message": message]
        ])
    }

    public static func isJSONRPCNotification(_ command: String) -> Bool {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCommand.hasPrefix("{"),
              let data = trimmedCommand.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              usesJSONRPC(dict) else {
            return false
        }
        return !dict.keys.contains("id")
    }

    public static func shouldWriteResponse(for command: String) -> Bool {
        !isJSONRPCNotification(command)
    }

    public static func shouldWriteResponse(for request: V2SocketRequest) -> Bool {
        !(request.usesJSONRPC && !request.hasIdMember)
    }

    public static func parseV2SocketRequest(_ command: String) -> V2SocketRequest? {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCommand.hasPrefix("{"),
              let data = trimmedCommand.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }

        return try? parseV2SocketRequestObject(dict)
    }

    public static func parseV2SocketRequestObject(_ dict: [String: Any]) throws -> V2SocketRequest {
        if dict.keys.contains("jsonrpc"), !usesJSONRPC(dict) {
            throw V2SocketRequestParseError.invalidJSONRPCVersion
        }

        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !method.isEmpty else {
            throw V2SocketRequestParseError.missingMethod
        }

        let usesJSONRPC = usesJSONRPC(dict)
        let hasIdMember = dict.keys.contains("id")
        if usesJSONRPC && hasIdMember && !isValidJSONRPCID(dict["id"]) {
            throw V2SocketRequestParseError.malformedID
        }
        let params = try paramsObject(in: dict)
        let id = usesJSONRPC ? validJSONRPCID(dict["id"]) : dict["id"]
        return V2SocketRequest(
            id: id,
            method: method,
            params: params,
            usesJSONRPC: usesJSONRPC,
            hasIdMember: hasIdMember
        )
    }

    public static func paramsObject(in dict: [String: Any]) throws -> [String: Any] {
        guard dict.keys.contains("params") else {
            return [:]
        }
        guard let params = dict["params"] as? [String: Any] else {
            throw V2SocketRequestParseError.invalidParams
        }
        return params
    }

    public static func validJSONRPCID(_ id: Any?) -> Any? {
        guard let id else { return nil }
        if id is NSNull || id is String {
            return id
        }
        if let number = id as? NSNumber {
            return CFGetTypeID(number) != CFBooleanGetTypeID() ? number : nil
        }
        return nil
    }

    public static func validJSONRPCIDOrNull(_ id: Any?) -> Any {
        validJSONRPCID(id) ?? NSNull()
    }

    public static func isValidJSONRPCID(_ id: Any?) -> Bool {
        guard id != nil else { return true }
        return validJSONRPCID(id) != nil
    }

    public static func unknownMethodMessage(_ method: String) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "socket.error.unknownMethod",
                defaultValue: "Unknown method: %@. Call system.capabilities to list supported methods."
            ),
            method
        )
    }

    public static func unknownVMMethodMessage(_ method: String) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "socket.error.unknownVMMethod",
                defaultValue: "Unknown VM method: %@. Call system.capabilities to list supported methods, then use a vm.* method from that list."
            ),
            method
        )
    }

    private static func topLevelObjectDeclaresJSONRPC2(_ command: String) -> Bool {
        var index = command.startIndex
        skipWhitespace(in: command, index: &index)
        guard consume("{", in: command, index: &index) else { return false }

        while index < command.endIndex {
            skipWhitespace(in: command, index: &index)
            if consume(",", in: command, index: &index) {
                continue
            }
            if consume("}", in: command, index: &index) {
                return false
            }

            guard let key = parseJSONString(in: command, index: &index) else {
                return false
            }
            skipWhitespace(in: command, index: &index)
            guard consume(":", in: command, index: &index) else {
                return false
            }
            skipWhitespace(in: command, index: &index)

            if key == "jsonrpc" {
                return parseJSONString(in: command, index: &index) == "2.0"
            }
            skipJSONValue(in: command, index: &index)
        }

        return false
    }

    private static func topLevelArrayDeclaresJSONRPC2(_ command: String) -> Bool {
        var index = command.startIndex
        skipWhitespace(in: command, index: &index)
        guard consume("[", in: command, index: &index) else { return false }
        skipWhitespace(in: command, index: &index)
        guard parseJSONString(in: command, index: &index) == "jsonrpc" else { return false }
        skipWhitespace(in: command, index: &index)
        guard consume(",", in: command, index: &index) else { return false }
        skipWhitespace(in: command, index: &index)
        return parseJSONString(in: command, index: &index) == "2.0"
    }

    private static func skipWhitespace(in string: String, index: inout String.Index) {
        while index < string.endIndex, string[index].isWhitespace {
            index = string.index(after: index)
        }
    }

    private static func consume(_ character: Character, in string: String, index: inout String.Index) -> Bool {
        guard index < string.endIndex, string[index] == character else {
            return false
        }
        index = string.index(after: index)
        return true
    }

    private static func parseJSONString(in string: String, index: inout String.Index) -> String? {
        guard consume("\"", in: string, index: &index) else { return nil }
        var value = ""
        var isEscaped = false
        while index < string.endIndex {
            let character = string[index]
            index = string.index(after: index)
            if isEscaped {
                value.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                return value
            } else {
                value.append(character)
            }
        }
        return nil
    }

    private static func skipJSONValue(in string: String, index: inout String.Index) {
        skipWhitespace(in: string, index: &index)
        guard index < string.endIndex else { return }
        if string[index] == "\"" {
            _ = parseJSONString(in: string, index: &index)
        } else if string[index] == "{" {
            skipEnclosedJSONValue(in: string, index: &index, open: "{", close: "}")
        } else if string[index] == "[" {
            skipEnclosedJSONValue(in: string, index: &index, open: "[", close: "]")
        } else {
            while index < string.endIndex, string[index] != ",", string[index] != "}" {
                index = string.index(after: index)
            }
        }
    }

    private static func skipEnclosedJSONValue(
        in string: String,
        index: inout String.Index,
        open: Character,
        close: Character
    ) {
        var depth = 0
        while index < string.endIndex {
            if string[index] == "\"" {
                _ = parseJSONString(in: string, index: &index)
                continue
            }
            if string[index] == open {
                depth += 1
            } else if string[index] == close {
                depth -= 1
                index = string.index(after: index)
                if depth == 0 {
                    return
                }
                continue
            }
            index = string.index(after: index)
        }
    }

    public static let socketWorkerV2Methods: Set<String> = [
        "auth.status",
        "auth.begin_sign_in",
        "auth.sign_out",
        "feedback.submit",
        "feed.push",
        "feed.permission.reply",
        "feed.question.reply",
        "feed.exit_plan.reply",
        "browser.download.wait",
        "browser.profiles.list",
        "browser.profiles.create",
        "browser.profiles.rename",
        "browser.profiles.clear",
        "browser.profiles.delete",
        "browser.import.cookies",
        "system.top",
    ]

    public static func executionPolicy(forV2Method method: String) -> SocketCommandExecutionPolicy {
        if method.hasPrefix("vm.") || socketWorkerV2Methods.contains(method) {
            return .socketWorker
        }
        return .mainActor
    }

    public static func orNull(_ value: Any?) -> Any {
        if let value { return value }
        return NSNull()
    }

    public static func encode(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              var string = String(data: data, encoding: .utf8) else {
            return encodeFailure(for: object)
        }

        string = string.replacingOccurrences(of: "\n", with: "\\n")
        return string
    }

    private static func encodeFailure(for object: Any) -> String {
        let message = String(localized: "socket.error.encodeJSON", defaultValue: "Failed to encode JSON")
        if let responseObject = object as? [String: Any], usesJSONRPC(responseObject) {
            return fallbackJSONString([
                "jsonrpc": "2.0",
                "id": validJSONValueOrNull(responseObject["id"]),
                "error": [
                    "code": -32603,
                    "message": message,
                    "data": ["cmux_code": "encode_error"]
                ]
            ])
        }
        return "{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"\(escapeJSONString(message))\"}}"
    }

    private static func validJSONValueOrNull(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        guard JSONSerialization.isValidJSONObject(["value": value]) else {
            return NSNull()
        }
        return value
    }

    private static func fallbackJSONString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              var string = String(data: data, encoding: .utf8) else {
            let message = String(localized: "socket.error.encodeJSON", defaultValue: "Failed to encode JSON")
            return "{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"\(escapeJSONString(message))\"}}"
        }
        string = string.replacingOccurrences(of: "\n", with: "\\n")
        return string
    }

    private static func escapeJSONString(_ string: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(string.count)
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22:
                escaped += "\\\""
            case 0x5C:
                escaped += "\\\\"
            case 0x0A:
                escaped += "\\n"
            case 0x0D:
                escaped += "\\r"
            case 0x09:
                escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped
    }

    public static func ok(id: Any?, jsonRPC: Bool, result: Any) -> String {
        if jsonRPC {
            return encode([
                "jsonrpc": "2.0",
                "id": orNull(id),
                "result": result
            ])
        }
        return encode([
            "id": orNull(id),
            "ok": true,
            "result": result
        ])
    }

    public static func error(id: Any?, jsonRPC: Bool, code: String, message: String, data: Any? = nil) -> String {
        if jsonRPC {
            var jsonRPCErrorData: [String: Any] = ["cmux_code": code]
            if let data {
                jsonRPCErrorData["details"] = data
            }
            return encode([
                "jsonrpc": "2.0",
                "id": orNull(id),
                "error": [
                    "code": jsonRPCErrorCode(for: code),
                    "message": message,
                    "data": jsonRPCErrorData
                ]
            ])
        }

        var err: [String: Any] = ["code": code, "message": message]
        if let data {
            err["data"] = data
        }
        return encode([
            "id": orNull(id),
            "ok": false,
            "error": err
        ])
    }

    public static func jsonRPCErrorCode(for code: String) -> Int {
        switch code {
        case "parse_error", "invalid_utf8":
            return -32700
        case "invalid_request":
            return -32600
        case "invalid_dispatch":
            return -32603
        case "method_not_found":
            return -32601
        case "invalid_params":
            return -32602
        default:
            return -32000
        }
    }

    public static func result(id: Any?, jsonRPC: Bool, _ result: V2CallResult) -> String {
        switch result {
        case .ok(let payload):
            return ok(id: id, jsonRPC: jsonRPC, result: payload)
        case .err(let code, let message, let data):
            return error(id: id, jsonRPC: jsonRPC, code: code, message: message, data: data)
        }
    }

    public static func eventStreamFrame(_ object: [String: Any], responseId: Any?) -> [String: Any] {
        if object["type"] as? String == "ack" {
            return [
                "jsonrpc": "2.0",
                "id": validJSONRPCIDOrNull(responseId),
                "result": object
            ]
        }

        let type = object["type"] as? String
        let method: String
        if type == "event", let name = object["name"] as? String, !name.isEmpty {
            method = name
        } else if let type, !type.isEmpty {
            method = "cmux.events.\(type)"
        } else {
            method = "cmux.events.message"
        }
        return [
            "jsonrpc": "2.0",
            "method": method,
            "params": object
        ]
    }
}

nonisolated public func v2OrNull(_ value: Any?) -> Any {
    CMUXSocketProtocol.orNull(value)
}

nonisolated public func v2Encode(_ object: Any) -> String {
    CMUXSocketProtocol.encode(object)
}

nonisolated public func v2Ok(id: Any?, jsonRPC: Bool, result: Any) -> String {
    CMUXSocketProtocol.ok(id: id, jsonRPC: jsonRPC, result: result)
}

nonisolated public func v2Error(id: Any?, jsonRPC: Bool, code: String, message: String, data: Any? = nil) -> String {
    CMUXSocketProtocol.error(id: id, jsonRPC: jsonRPC, code: code, message: message, data: data)
}

nonisolated public func v2Result(id: Any?, jsonRPC: Bool, _ result: V2CallResult) -> String {
    CMUXSocketProtocol.result(id: id, jsonRPC: jsonRPC, result)
}
