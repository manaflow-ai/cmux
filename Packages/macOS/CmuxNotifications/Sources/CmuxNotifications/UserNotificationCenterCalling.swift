@preconcurrency import UserNotifications

/// The callback-based framework surface isolated behind ``UserNotificationCenterService``.
protocol UserNotificationCenterCalling: AnyObject {
    var delegate: (any UNUserNotificationCenterDelegate)? { get set }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)

    func getNotificationCategories(
        completionHandler: @escaping @Sendable (Set<UNNotificationCategory>) -> Void
    )

    func getNotificationSettings(
        completionHandler: @escaping @Sendable (UNNotificationSettings) -> Void
    )

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void
    )

    func add(
        _ request: UNNotificationRequest,
        withCompletionHandler completionHandler: (@Sendable ((any Error)?) -> Void)?
    )

    func removeDeliveredNotifications(withIdentifiers identifiers: [String])

    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: UserNotificationCenterCalling {}
