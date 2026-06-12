import Foundation
import UserNotifications

struct NativeNotificationDeliveryHooks {
    var authorizationHandlerForTesting: ((@escaping (Bool) -> Void) -> Void)?
    var scheduler: (UNNotificationRequest, @escaping (Error?) -> Void) -> Void = {
        request,
        completion in
        UNUserNotificationCenter.current().add(request, withCompletionHandler: completion)
    }
    var commandRunner: (String, String, String) -> Void = {
        title,
        subtitle,
        body in
        NotificationSoundSettings.runCustomCommand(title: title, subtitle: subtitle, body: body)
    }

    func authorizeForTesting(_ completion: @escaping (Bool) -> Void) -> Bool {
        guard let authorizationHandlerForTesting else {
            return false
        }
        authorizationHandlerForTesting(completion)
        return true
    }

    func schedule(
        _ request: UNNotificationRequest,
        completion: @escaping (Error?) -> Void
    ) {
        scheduler(request, completion)
    }

    func runCommand(title: String, subtitle: String, body: String) {
        commandRunner(title, subtitle, body)
    }

}
