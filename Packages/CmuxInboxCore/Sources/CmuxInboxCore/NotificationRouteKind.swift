import Foundation

/// The kind of deep link carried by a remote notification route.
public enum NotificationRouteKind: String, Codable, Equatable, Sendable {
    /// A route that opens a terminal workspace.
    case workspace
}
