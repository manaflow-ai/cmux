import Foundation
import UserNotifications

struct NotificationDeliveryResponse {
    let categoryIdentifier: String
    let actionIdentifier: String
    let requestIdentifier: String
    let userInfo: [AnyHashable: Any]

    init(
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

    init(_ response: UNNotificationResponse) {
        self.init(
            categoryIdentifier: response.notification.request.content.categoryIdentifier,
            actionIdentifier: response.actionIdentifier,
            requestIdentifier: response.notification.request.identifier,
            userInfo: response.notification.request.content.userInfo
        )
    }
}
