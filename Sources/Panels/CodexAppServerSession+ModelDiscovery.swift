import Foundation

@MainActor
extension CodexAppServerSession {
    func handleModelResponse(id: Int, object: [String: Any]) -> Bool {
        guard id == modelCatalog.requestID else { return false }
        modelCatalog.requestID = nil
        guard object["error"] == nil, let result = object["result"] as? [String: Any] else { return true }
        if let cursor = modelCatalog.append(result) {
            Task { @MainActor in try? await requestModelPage(cursor: cursor) }
        } else {
            modelsSink?(modelCatalog.models)
        }
        return true
    }

    func requestModelPage(cursor: String? = nil) async throws {
        var params: [String: Any] = ["limit": 100, "includeHidden": false]
        if let cursor { params["cursor"] = cursor }
        try await sendRequest(method: "model/list", params: params, register: { self.modelCatalog.requestID = $0 })
    }

}
