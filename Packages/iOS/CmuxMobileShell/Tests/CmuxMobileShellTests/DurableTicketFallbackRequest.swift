import Foundation

struct DurableTicketFallbackRequest: Sendable {
    var id: String?
    var method: String?
    var workspaceID: String?
    var attachToken: String?
    var stackAccessToken: String?

    init(payload: Data) throws {
        let request = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let params = request?["params"] as? [String: Any]
        let auth = request?["auth"] as? [String: Any]
        id = request?["id"] as? String
        method = request?["method"] as? String
        workspaceID = params?["workspace_id"] as? String
        attachToken = auth?["attach_token"] as? String
        stackAccessToken = auth?["stack_access_token"] as? String
    }
}
