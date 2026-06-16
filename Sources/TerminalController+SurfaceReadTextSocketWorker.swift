import CmuxControlSocket
import Foundation

private let surfaceReadTextReadinessWaiter = SurfaceReadTextReadinessWaiter(maxWaiters: 16)

extension TerminalController {
    nonisolated func socketWorkerSurfaceReadTextResult(_ request: ControlRequest) async -> V2CallResult {
        let firstResult = socketWorkerCoordinatorResult(for: request)
        guard let surfaceID = Self.retryableReadDemandSurfaceID(
            from: firstResult,
            request: request
        ) else {
            return Self.v2CallResult(from: firstResult)
        }

        guard let readinessWait = await surfaceReadTextReadinessWaiter.prepareWait(for: surfaceID) else {
            return Self.v2CallResult(from: firstResult)
        }

        let retryRequest = Self.readTextRequest(request, pinnedToSurfaceID: surfaceID)
        let secondResult = socketWorkerCoordinatorResult(for: retryRequest)
        guard Self.retryableReadDemandSurfaceID(from: secondResult, request: retryRequest) == surfaceID else {
            await surfaceReadTextReadinessWaiter.cancel(readinessWait)
            return Self.v2CallResult(from: secondResult)
        }

        guard await surfaceReadTextReadinessWaiter.wait(readinessWait) else {
            return Self.v2CallResult(from: secondResult)
        }

        let readyResult = socketWorkerCoordinatorResult(for: retryRequest)
        return Self.v2CallResult(from: readyResult)
    }

    private nonisolated func socketWorkerCoordinatorResult(for request: ControlRequest) -> ControlCallResult {
        v2MainSync {
            v2RefreshKnownRefs()
            return controlCommandCoordinator.handle(request) ?? .err(
                code: "method_not_found",
                message: "Unknown method",
                data: nil
            )
        }
    }

    private nonisolated static func retryableReadDemandSurfaceID(
        from result: ControlCallResult,
        request: ControlRequest
    ) -> UUID? {
        guard request.method == "surface.read_text",
              v2BoolValue(request.params["start_if_needed"]) == true,
              case .err(let code, _, let data) = result,
              code == "terminal_not_ready",
              case .object(let object)? = data,
              case .string(let rawSurfaceID)? = object["surface_id"] else {
            return nil
        }
        return UUID(uuidString: rawSurfaceID)
    }

    private nonisolated static func readTextRequest(
        _ request: ControlRequest,
        pinnedToSurfaceID surfaceID: UUID
    ) -> ControlRequest {
        var params = request.params
        params["surface_id"] = .string(surfaceID.uuidString)
        return ControlRequest(id: request.id, method: request.method, params: params)
    }

    private nonisolated static func v2CallResult(from result: ControlCallResult) -> V2CallResult {
        switch result {
        case .ok(let payload):
            return .ok(payload.foundationObject)
        case .err(let code, let message, let data):
            return .err(code: code, message: message, data: data?.foundationObject)
        }
    }

    private nonisolated static func v2BoolValue(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let value):
            return value
        case .int(let value):
            return value != 0
        case .double(let value):
            return value != 0
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
