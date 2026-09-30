import CmuxAcpmux
import CmuxAgentChat
import Foundation

/// Mobile RPC handlers for the native acpmux conversation GUI. ACP details are
/// contained in ``AcpmuxMobileBridge``; this file only translates authenticated
/// mobile requests into JSON-safe wire payloads.
extension TerminalController {
    func v2MobileAcpmuxDispatch(method: String, params: [String: Any]) async -> V2CallResult {
        let bridge = acpmuxMobileBridgeIfNeeded()
        do {
            switch method {
            case "mobile.acpmux.sessions":
                let sessions = try await bridge.sessions()
                return .ok(["sessions": try wireObject(sessions)])
            case "mobile.acpmux.session":
                guard let sessionID = v2String(params, "session_id") else {
                    return .err(code: "invalid_params", message: "session_id is required", data: nil)
                }
                let session = try await bridge.session(sessionID: sessionID)
                return .ok(["session": try wireObject(session)])
            case "mobile.acpmux.session.new":
                let id = try await bridge.createSession(
                    harness: v2String(params, "harness"),
                    workingDirectory: v2String(params, "cwd")
                )
                return .ok(["session_id": id])
            case "mobile.acpmux.history":
                guard let sessionID = v2String(params, "session_id") else {
                    return .err(code: "invalid_params", message: "session_id is required", data: nil)
                }
                let page = try await bridge.history(
                    sessionID: sessionID,
                    beforeSeq: v2Int(params, "before_seq")
                )
                return .ok(try wireObject(page))
            case "mobile.acpmux.send":
                guard let sessionID = v2String(params, "session_id"),
                      let text = v2String(params, "text") else {
                    return .err(code: "invalid_params", message: "session_id and text are required", data: nil)
                }
                try await bridge.send(sessionID: sessionID, text: text)
                return .ok(["accepted": true])
            case "mobile.acpmux.cancel":
                guard let sessionID = v2String(params, "session_id") else {
                    return .err(code: "invalid_params", message: "session_id is required", data: nil)
                }
                try await bridge.cancel(sessionID: sessionID)
                return .ok(["accepted": true])
            case "mobile.acpmux.answer":
                guard let sessionID = v2String(params, "session_id"),
                      let optionIndex = v2Int(params, "option_index") else {
                    return .err(code: "invalid_params", message: "session_id and option_index are required", data: nil)
                }
                try await bridge.answer(sessionID: sessionID, optionIndex: optionIndex)
                return .ok(["accepted": true])
            default:
                return .err(code: "method_not_found", message: "Unknown mobile acpmux method", data: ["method": method])
            }
        } catch let error as AcpmuxMobileBridgeError {
            switch error {
            case .requestFailed(let message):
                return .err(code: "acpmux_unavailable", message: message, data: nil)
            }
        } catch {
            return .err(code: "acpmux_unavailable", message: error.localizedDescription, data: nil)
        }
    }

    private func acpmuxMobileBridgeIfNeeded() -> AcpmuxMobileBridge {
        if let bridge = acpmuxMobileBridge { return bridge }
        let bridge = AcpmuxMobileBridge(connector: makeAcpmuxMobileConnector())
        acpmuxMobileBridge = bridge
        return bridge
    }

    private func wireObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try ChatWireCoding().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }
}
