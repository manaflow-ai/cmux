import Foundation

struct MobileNotificationFeedWireItem: Sendable {
    let id: String
    let workspaceID: String
    let surfaceID: String?
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Double
    let isRead: Bool
    let retargetsToLiveSurfaceOwner: Bool
    let workspaceTitle: String?
    let surfaceTitle: String?

    var foundationPayload: [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "workspace_id": workspaceID,
            "title": title,
            "subtitle": subtitle,
            "body": body,
            "created_at": createdAt,
            "is_read": isRead,
            "retargets_to_live_surface_owner": retargetsToLiveSurfaceOwner,
        ]
        if let surfaceID {
            payload["surface_id"] = surfaceID
        }
        if let workspaceTitle {
            payload["workspace_title"] = workspaceTitle
        }
        if let surfaceTitle {
            payload["surface_title"] = surfaceTitle
        }
        return payload
    }
}
