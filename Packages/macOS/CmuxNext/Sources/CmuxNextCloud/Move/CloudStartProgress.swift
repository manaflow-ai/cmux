public import Foundation

/// Setup progress returned with a Cloud start plan and forwarded to the startup card.
public struct CloudStartSetup: Sendable, Equatable {
    public var state: String?
    public var status: String?
    public var startedAt: Double?
    public var finishedAt: Double?
    public var error: String?
    public var hasScript: Bool?

    public init?(object: [String: Any]) {
        state = object["state"] as? String
        status = object["status"] as? String
        startedAt = object["started_at"] as? Double ?? object["startedAt"] as? Double
        finishedAt = object["finished_at"] as? Double ?? object["finishedAt"] as? Double
        error = object["error"] as? String
        hasScript = object["has_script"] as? Bool ?? object["hasScript"] as? Bool
        guard state != nil || status != nil || startedAt != nil || finishedAt != nil || error != nil || hasScript != nil else { return nil }
    }
}

/// The environment and setup state carried by a `link start-chat plan` answer.
public struct CloudStartInfo: Sendable, Equatable {
    public var environmentId: String?
    public var setup: CloudStartSetup?

    public init(object: [String: Any]) {
        let ensured = object["ensured"] as? [String: Any]
        let environment = (ensured?["environment"] as? [String: Any]) ?? (object["environment"] as? [String: Any])
        let setup = ensured?["setup"] as? [String: Any] ?? object["setup"] as? [String: Any]
        environmentId = ensured?["environment_id"] as? String ?? object["environment_id"] as? String ?? environment?["id"] as? String
        self.setup = setup.flatMap(CloudStartSetup.init(object:))
    }
}
