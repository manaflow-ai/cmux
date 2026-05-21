import Foundation

enum CMUXSudoJSONValue: Sendable {
    case string(String)
    case int(Int)
    case null

    var any: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .null: return NSNull()
        }
    }
}

struct CMUXSudoSocketResponse: Sendable {
    let ok: Bool
    let payload: [String: CMUXSudoJSONValue]
    let code: String?
    let message: String?
    let data: [String: CMUXSudoJSONValue]?

    static func ok(_ payload: [String: CMUXSudoJSONValue]) -> CMUXSudoSocketResponse {
        .init(ok: true, payload: payload, code: nil, message: nil, data: nil)
    }

    static func err(
        code: String,
        message: String,
        data: [String: CMUXSudoJSONValue]? = nil
    ) -> CMUXSudoSocketResponse {
        .init(ok: false, payload: [:], code: code, message: message, data: data)
    }
}

extension CMUXSudoSocketResponse {
    func toV2CallResult() -> TerminalController.V2CallResult {
        if ok {
            return .ok(payload.mapValues { $0.any })
        }
        return .err(
            code: code ?? "sudo_error",
            message: message ?? String(localized: "sudo.error.helperFailed", defaultValue: "sudo helper failed"),
            data: data?.mapValues { $0.any }
        )
    }
}
