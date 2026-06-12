import UserNotifications

extension TerminalNotificationStore {
    func configureNotificationAuthorizationHandlerForTesting(
        _ handler: @escaping (@escaping (Bool) -> Void) -> Void
    ) {
        nativeNotificationDeliveryHooks.authorizationHandlerForTesting = handler
    }

    func resetNotificationAuthorizationHandlerForTesting() {
        nativeNotificationDeliveryHooks.authorizationHandlerForTesting = nil
    }

    func configureUserNotificationSchedulerForTesting(
        _ scheduler: @escaping (UNNotificationRequest, @escaping (Error?) -> Void) -> Void
    ) {
        nativeNotificationDeliveryHooks.scheduler = scheduler
    }

    func resetUserNotificationSchedulerForTesting() {
        nativeNotificationDeliveryHooks.scheduler = { request, completion in
            UNUserNotificationCenter.current().add(request, withCompletionHandler: completion)
        }
    }

    func configureNotificationCommandRunnerForTesting(
        _ runner: @escaping (String, String, String) -> Void
    ) {
        nativeNotificationDeliveryHooks.commandRunner = runner
    }

    func resetNotificationCommandRunnerForTesting() {
        nativeNotificationDeliveryHooks.commandRunner = { title, subtitle, body in
            NotificationSoundSettings.runCustomCommand(title: title, subtitle: subtitle, body: body)
        }
    }
}
