import Foundation

/// A deep link parsed from a remote notification payload, identifying the destination to open.
public struct NotificationRoute: Codable, Equatable, Sendable {
    /// The kind of destination this route opens.
    public let kind: NotificationRouteKind
    /// The workspace identifier to open.
    public let workspaceID: String
    /// The machine identifier hosting the workspace, if provided.
    public let machineID: String?

    /// Creates a notification route from its components.
    ///
    /// - Parameters:
    ///   - kind: The kind of destination this route opens.
    ///   - workspaceID: The workspace identifier to open.
    ///   - machineID: The machine identifier hosting the workspace, if provided.
    public init(kind: NotificationRouteKind, workspaceID: String, machineID: String?) {
        self.kind = kind
        self.workspaceID = workspaceID
        self.machineID = machineID
    }

    /// Parses a notification route from an APNs `userInfo` payload, if present and well-formed.
    ///
    /// The route may be carried either as a nested dictionary under the `"route"` key or as a JSON string under
    /// the same key. Returns `nil` when the payload contains no recognizable route.
    ///
    /// - Parameter userInfo: The `userInfo` dictionary delivered with a remote notification.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let routeObject = userInfo["route"] else {
            return nil
        }

        if let route = routeObject as? [String: Any] {
            guard let kindRaw = route["kind"] as? String,
                  let kind = NotificationRouteKind(rawValue: kindRaw),
                  let workspaceID = route["workspaceId"] as? String else {
                return nil
            }
            self.init(
                kind: kind,
                workspaceID: workspaceID,
                machineID: route["machineId"] as? String
            )
            return
        }

        if let routeString = routeObject as? String,
           let data = routeString.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(NotificationRoutePayload.self, from: data),
           let kind = NotificationRouteKind(rawValue: decoded.kind) {
            self.init(kind: kind, workspaceID: decoded.workspaceId, machineID: decoded.machineId)
            return
        }

        return nil
    }
}

/// The wire shape of a notification route delivered as a JSON string.
private struct NotificationRoutePayload: Decodable {
    let kind: String
    let workspaceId: String
    let machineId: String?
}
