import Foundation
public import UserNotifications

/// Platform-neutral notification response data consumed by the delivery coordinator.
public struct NotificationDeliveryResponse {
    /// Notification category identifier supplied by the OS request.
    public let categoryIdentifier: String
    /// Action identifier selected by the user or system.
    public let actionIdentifier: String
    /// Stable request identifier used to recover the notification id.
    public let requestIdentifier: String
    /// Serialized routing metadata attached when the notification was scheduled.
    public let userInfo: [AnyHashable: Any]

    /// Creates decoded notification-response data.
    ///
    /// - Parameters:
    ///   - categoryIdentifier: Notification category identifier.
    ///   - actionIdentifier: Selected action identifier.
    ///   - requestIdentifier: Stable request identifier.
    ///   - userInfo: Serialized routing metadata.
    public init(
        categoryIdentifier: String,
        actionIdentifier: String,
        requestIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) {
        self.categoryIdentifier = categoryIdentifier
        self.actionIdentifier = actionIdentifier
        self.requestIdentifier = requestIdentifier
        self.userInfo = userInfo
    }

    /// Decodes a native user-notification response.
    ///
    /// - Parameter response: Native response received from `UNUserNotificationCenter`.
    public init(_ response: UNNotificationResponse) {
        self.init(
            categoryIdentifier: response.notification.request.content.categoryIdentifier,
            actionIdentifier: response.actionIdentifier,
            requestIdentifier: response.notification.request.identifier,
            userInfo: response.notification.request.content.userInfo
        )
    }
}
