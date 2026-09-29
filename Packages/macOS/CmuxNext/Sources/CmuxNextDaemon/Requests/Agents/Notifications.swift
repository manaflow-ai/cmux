import Foundation

public struct NotifyRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var notification: NotificationID
    }
    public static let command = "notify"
    public var title: String
    public var body: String
    public var level: NotificationLevel?
    public var surface: SurfaceID?
    public init(title: String, body: String = "", level: NotificationLevel? = nil, surface: SurfaceID? = nil) {
        self.title = title
        self.body = body
        self.level = level
        self.surface = surface
    }
}

/// TODO(feat-cmux-next-daemon): proposed raw `notification-ack` (v2 already
/// has `notification.ack`); not on that branch yet. Clears the unread marker
/// without "selecting".
public struct AckNotificationRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "notification-ack"
    public var notification: NotificationID?
    public var surface: SurfaceID?
    public init(notification: NotificationID? = nil, surface: SurfaceID? = nil) {
        self.notification = notification
        self.surface = surface
    }
}
