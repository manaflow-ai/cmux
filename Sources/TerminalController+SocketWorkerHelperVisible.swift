import CmuxControlSocket
import Foundation

extension TerminalController {
    nonisolated static func typedRequest(from request: V2SocketRequest) -> ControlRequest? {
        let id: JSONValue?
        if let rawID = request.id {
            guard let value = JSONValue(foundationObject: rawID) else { return nil }
            id = value
        } else {
            id = nil
        }
        guard let params = JSONValue(foundationObject: request.params),
              case .object(let typedParams) = params else {
            return nil
        }
        return ControlRequest(id: id, method: request.method, params: typedParams)
    }

    nonisolated static func feedPushWaitTimeoutSeconds(params: [String: Any]) -> TimeInterval? {
        guard let rawTimeout = params["wait_timeout_seconds"] else {
            return 0
        }
        let seconds: Double?
        if let number = rawTimeout as? NSNumber {
            seconds = number.doubleValue
        } else if let value = rawTimeout as? Double {
            seconds = value
        } else if let value = rawTimeout as? Int {
            seconds = Double(value)
        } else {
            seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds >= 0, seconds <= 120 else {
            return nil
        }
        return seconds
    }

    nonisolated func v2HelperVisibleResponse(_ request: V2SocketRequest) -> String {
        guard let typedRequest = Self.typedRequest(from: request) else {
            return v2Error(id: request.id, code: "invalid_request", message: "Invalid helper.visible request")
        }
        return v2AsyncResultCall(id: request.id, timeoutSeconds: 2) {
            let result = await self.controlCommandCoordinator.handleAsync(typedRequest)
                ?? .err(code: "method_not_found", message: "Unknown method", data: nil)
            return self.v2CallResult(from: result)
        }
    }

    nonisolated func v2CallResult(from result: ControlCallResult) -> V2CallResult {
        switch result {
        case .ok(let payload):
            return .ok(payload.foundationObject)
        case .err(let code, let message, let data):
            return .err(code: code, message: message, data: data?.foundationObject)
        }
    }
}
