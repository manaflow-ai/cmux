import Foundation

extension TerminalController {
    /// A worker-lane read: only the immutable owner capture requires the main actor.
    nonisolated func socketWorkerCurrentWorkResponse(id: Any?, params: [String: Any]) -> String {
        let limit: Int
        if let raw = params["limit"] {
            guard let number = raw as? NSNumber,
                  let parsedLimit = v2StrictIntAny(number),
                  (1...200).contains(parsedLimit) else {
                return v2Error(id: id, code: "invalid_params", message: "current.list limit must be an integer from 1 to 200")
            }
            limit = parsedLimit
        } else { limit = 100 }
        guard Set(params.keys).isSubset(of: ["limit"]) else {
            return v2Error(id: id, code: "invalid_params", message: "current.list accepts only limit; it never refreshes or mutates work")
        }
        return v2VmCall(id: id, timeoutSeconds: 10) {
            guard let input = await Self.captureCurrentWork() else {
                throw SurfaceCatalogError.unsupported("Current-work owners are unavailable")
            }
            return try CurrentWorkReducer().reduce(input, limit: limit).jsonObject()
        }
    }

    @MainActor
    private static func captureCurrentWork() -> CurrentWorkInput? {
        AppDelegate.shared?.currentWorkQueryService().capture()
    }
}
