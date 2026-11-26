import Foundation
import UserNotifications

struct NotificationDeliveryResponse {
    let categoryIdentifier: String
    let actionIdentifier: String
    let requestIdentifier: String
    let userInfo: [AnyHashable: Any]
    let userText: String?

    init(
        categoryIdentifier: String,
        actionIdentifier: String,
        requestIdentifier: String,
        userInfo: [AnyHashable: Any],
        userText: String? = nil
    ) {
        self.categoryIdentifier = categoryIdentifier
        self.actionIdentifier = actionIdentifier
        self.requestIdentifier = requestIdentifier
        self.userInfo = userInfo
        self.userText = userText
    }

    init(_ response: UNNotificationResponse) {
        self.init(
            categoryIdentifier: response.notification.request.content.categoryIdentifier,
            actionIdentifier: response.actionIdentifier,
            requestIdentifier: response.notification.request.identifier,
            userInfo: response.notification.request.content.userInfo,
            userText: (response as? UNTextInputNotificationResponse)?.userText
        )
    }
}
