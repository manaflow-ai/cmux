import CmuxControlSocket
import Foundation

/// Bridges between the legacy Foundation-shaped `V2CallResult` / encoded
/// response strings and the typed ``ControlCallResult`` the socket lanes and
/// the read-snapshot store speak.
extension TerminalController {
    nonisolated static func controlCallResult(
        fromEncodedResponse response: String
    ) -> ControlCallResult? {
        guard let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? Bool else {
            return nil
        }
        if ok {
            guard let rawResult = object["result"],
                  let result = JSONValue(foundationObject: rawResult) else {
                return nil
            }
            return .ok(result)
        }
        guard let error = object["error"] as? [String: Any],
              let code = error["code"] as? String,
              let message = error["message"] as? String else {
            return nil
        }
        return .err(
            code: code,
            message: message,
            data: error["data"].flatMap(JSONValue.init(foundationObject:))
        )
    }

    nonisolated static func controlCallResult(
        fromLegacy result: V2CallResult
    ) -> ControlCallResult {
        switch result {
        case .ok(let payload):
            guard let value = JSONValue(foundationObject: payload) else {
                return .err(
                    code: "encode_error",
                    message: "Failed to encode JSON",
                    data: nil
                )
            }
            return .ok(value)
        case .err(let code, let message, let data):
            return .err(
                code: code,
                message: message,
                data: data.flatMap(JSONValue.init(foundationObject:))
            )
        }
    }
}
