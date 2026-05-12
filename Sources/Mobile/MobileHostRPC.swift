import Foundation

struct MobileHostRPCRequest: @unchecked Sendable {
    let id: Any?
    let method: String
    let params: [String: Any]
}

struct MobileHostRPCError: Error, @unchecked Sendable {
    let code: String
    let message: String
    let data: Any?

    init(code: String, message: String, data: Any? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

enum MobileHostRPCResult: @unchecked Sendable {
    case ok(Any)
    case failure(MobileHostRPCError)
}

enum MobileHostRPCEnvelope {
    static func decodeRequest(_ data: Data) -> Result<MobileHostRPCRequest, MobileHostRPCError> {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(MobileHostRPCError(code: "parse_error", message: "Invalid JSON"))
        }

        guard let dict = object as? [String: Any] else {
            return .failure(MobileHostRPCError(code: "invalid_request", message: "Expected JSON object"))
        }

        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !method.isEmpty else {
            return .failure(MobileHostRPCError(code: "invalid_request", message: "Missing method"))
        }

        return .success(
            MobileHostRPCRequest(
                id: dict["id"],
                method: method,
                params: dict["params"] as? [String: Any] ?? [:]
            )
        )
    }

    static func encodeResponse(id: Any?, result: MobileHostRPCResult) -> Data {
        switch result {
        case let .ok(payload):
            return jsonData([
                "id": jsonValue(id),
                "ok": true,
                "result": jsonValue(payload)
            ])
        case let .failure(error):
            var errorPayload: [String: Any] = [
                "code": error.code,
                "message": error.message
            ]
            if let data = error.data {
                errorPayload["data"] = jsonValue(data)
            }
            return jsonData([
                "id": jsonValue(id),
                "ok": false,
                "error": errorPayload
            ])
        }
    }

    static func ok(id: Any?, _ payload: Any) -> Data {
        encodeResponse(id: id, result: .ok(payload))
    }

    static func error(id: Any?, code: String, message: String, data: Any? = nil) -> Data {
        encodeResponse(
            id: id,
            result: .failure(MobileHostRPCError(code: code, message: message, data: data))
        )
    }

    private static func jsonValue(_ value: Any?) -> Any {
        guard let value else {
            return NSNull()
        }
        if JSONSerialization.isValidJSONObject(["value": value]) {
            return value
        }
        return String(describing: value)
    }

    private static func jsonData(_ object: Any) -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return Data(
                #"{"id":null,"ok":false,"error":{"code":"encode_error","message":"Failed to encode JSON"}}"#.utf8
            )
        }
        return data
    }
}
