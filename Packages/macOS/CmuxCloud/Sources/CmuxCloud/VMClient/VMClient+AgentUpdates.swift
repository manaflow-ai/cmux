import Foundation

extension VMClient {
    /// Sets whether the machine keeps its image's coding agents or updates them
    /// along each agent's GitHub releases on attach. A running machine hears it right away; the
    /// server answers with the stored setting.
    public func setAgentUpdates(id: String, setting: CloudAgentUpdates) async throws -> CloudAgentUpdates {
        try await withOperation(.agentUpdates, foreground: true) {
            let encodedID = try pathSegment(id, fieldName: "vm id")
            let (data, http) = try await request(
                "PUT",
                path: "/api/vm/\(encodedID)/agent-updates",
                jsonBody: Self.agentUpdatesRequestBody(setting),
                timeoutSeconds: 30
            )
            try ensureOK(http, data: data)
            return try Self.decodeAgentUpdatesResponse(decodeJSONObject(data))
        }
    }

    /// `PUT /api/vm/{id}/agent-updates` body.
    public static func agentUpdatesRequestBody(_ setting: CloudAgentUpdates) -> [String: Any] {
        ["agentUpdates": setting.rawValue]
    }

    /// `{ id, agentUpdates }`; a missing or unknown value is a malformed answer.
    public static func decodeAgentUpdatesResponse(_ object: [String: Any]) throws -> CloudAgentUpdates {
        guard let setting = CloudAgentUpdates(wireValue: object["agentUpdates"]) else {
            throw VMClientError.malformedResponse("Cloud VM agent-updates response was missing agentUpdates.")
        }
        return setting
    }
}
