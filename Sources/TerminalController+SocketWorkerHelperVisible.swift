import CmuxControlSocket
import Dispatch
import Foundation

extension TerminalController {
    nonisolated private static let helperVisibleMutationStartDeadlineParam =
        "_cmux_helper_visible_latest_mutation_start_uptime_ns"
    nonisolated private static let helperVisibleTimeoutSeconds: TimeInterval = 8
    nonisolated private static let helperVisiblePostMutationBudgetSeconds: TimeInterval = 3

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
        var params = typedRequest.params
        let latestMutationStart = DispatchTime.now().uptimeNanoseconds
            + UInt64((Self.helperVisibleTimeoutSeconds - Self.helperVisiblePostMutationBudgetSeconds) * 1_000_000_000)
        params[Self.helperVisibleMutationStartDeadlineParam] = .int(Int64(latestMutationStart))
        let deadlineRequest = ControlRequest(id: typedRequest.id, method: typedRequest.method, params: params)
        return v2AsyncResultCall(id: request.id, timeoutSeconds: Self.helperVisibleTimeoutSeconds) {
            let result = await self.controlCommandCoordinator.handleAsync(deadlineRequest)
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
