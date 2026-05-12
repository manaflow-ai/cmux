import Foundation

private final class VMCallResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<[String: Any], Error>?

    func set(_ result: Result<[String: Any], Error>) {
        lock.lock()
        storage = result
        lock.unlock()
    }

    func get() -> Result<[String: Any], Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct VMCallWork: @unchecked Sendable {
    let run: () async throws -> [String: Any]
}

public enum SocketCommandExecutionPolicy: Equatable {
    case mainActor
    case socketWorker
}

public struct V2SocketRequest {
    public let id: Any?
    public let method: String
    public let params: [String: Any]
    public let usesJSONRPC: Bool
    public let hasIdMember: Bool

    public var isJSONRPCNotification: Bool {
        usesJSONRPC && !hasIdMember
    }
}

public enum V2CallResult {
    case ok(Any)
    case err(code: String, message: String, data: Any?)
}

public enum CMUXSocketProtocol {
    public static func usesJSONRPC(_ dict: [String: Any]) -> Bool {
        (dict["jsonrpc"] as? String) == "2.0"
    }

    public static func isJSONRPCNotification(_ command: String) -> Bool {
        guard let request = parseV2SocketRequest(command) else {
            return false
        }
        return request.isJSONRPCNotification
    }

    public static func parseV2SocketRequest(_ command: String) -> V2SocketRequest? {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCommand.hasPrefix("{"),
              let data = trimmedCommand.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }

        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !method.isEmpty else {
            return nil
        }

        return V2SocketRequest(
            id: dict["id"],
            method: method,
            params: dict["params"] as? [String: Any] ?? [:],
            usesJSONRPC: usesJSONRPC(dict),
            hasIdMember: dict.keys.contains("id")
        )
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
            return "{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"Failed to encode JSON\"}}"
        }

        string = string.replacingOccurrences(of: "\n", with: "\\n")
        return string
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
        var err: [String: Any] = ["code": code, "message": message]
        if let data {
            err["data"] = data
        }
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
        return encode([
            "id": orNull(id),
            "ok": false,
            "error": err
        ])
    }

    public static func jsonRPCErrorCode(for code: String) -> Int {
        switch code {
        case "parse_error":
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

    public static func vmCall(
        id: Any?,
        jsonRPC: Bool,
        timeoutSeconds: TimeInterval = 17 * 60,
        _ work: @escaping () async throws -> [String: Any]
    ) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = VMCallResultBox()
        let wrappedWork = VMCallWork(run: work)
        let task = Task {
            do {
                resultBox.set(.success(try await wrappedWork.run()))
            } catch {
                resultBox.set(.failure(error))
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            task.cancel()
            return error(
                id: id,
                jsonRPC: jsonRPC,
                code: "timeout",
                message: "VM request timed out after \(Int(timeoutSeconds)) seconds"
            )
        }
        switch resultBox.get() {
        case .success(let payload):
            return ok(id: id, jsonRPC: jsonRPC, result: payload)
        case .failure(let failure):
            return error(
                id: id,
                jsonRPC: jsonRPC,
                code: "vm_error",
                message: String(describing: failure)
            )
        case nil:
            return error(
                id: id,
                jsonRPC: jsonRPC,
                code: "vm_error",
                message: "unknown vm error"
            )
        }
    }

    public static func eventStreamFrame(_ object: [String: Any], responseId: Any?) -> [String: Any] {
        if object["type"] as? String == "ack" {
            return [
                "jsonrpc": "2.0",
                "id": orNull(responseId),
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

public func v2OrNull(_ value: Any?) -> Any {
    CMUXSocketProtocol.orNull(value)
}

public func v2Encode(_ object: Any) -> String {
    CMUXSocketProtocol.encode(object)
}

public func v2Ok(id: Any?, jsonRPC: Bool, result: Any) -> String {
    CMUXSocketProtocol.ok(id: id, jsonRPC: jsonRPC, result: result)
}

public func v2Error(id: Any?, jsonRPC: Bool, code: String, message: String, data: Any? = nil) -> String {
    CMUXSocketProtocol.error(id: id, jsonRPC: jsonRPC, code: code, message: message, data: data)
}

public func v2Result(id: Any?, jsonRPC: Bool, _ result: V2CallResult) -> String {
    CMUXSocketProtocol.result(id: id, jsonRPC: jsonRPC, result)
}

public func v2VmCall(
    id: Any?,
    jsonRPC: Bool,
    timeoutSeconds: TimeInterval = 17 * 60,
    _ work: @escaping () async throws -> [String: Any]
) -> String {
    CMUXSocketProtocol.vmCall(id: id, jsonRPC: jsonRPC, timeoutSeconds: timeoutSeconds, work)
}
