import Foundation
import UserNotifications

struct NativeNotificationDeliveryHooks {
    var authorizationHandlerForTesting: ((@escaping (Bool, NotificationAuthorizationState) -> Void) -> Void)?
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

    func authorizeForTesting(_ completion: @escaping (Bool, NotificationAuthorizationState) -> Void) -> Bool {
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

    func runLocalFeedback(
        title: String,
        subtitle: String,
        body: String,
        effects: TerminalNotificationPolicyEffects,
        runCommand: Bool = true
    ) {
        Self.runLocalFeedback(
            title: title,
            subtitle: subtitle,
            body: body,
            effects: effects,
            runCommand: runCommand,
            commandRunner: commandRunner
        )
    }

    static func playNativeUnavailableFeedback(effects: TerminalNotificationPolicyEffects) {
        if effects.sound {
            NotificationSoundSettings.playSelectedSound()
        }
    }

    static func runLocalFeedback(
        title: String,
        subtitle: String,
        body: String,
        effects: TerminalNotificationPolicyEffects,
        runCommand: Bool = true,
        commandRunner: (String, String, String) -> Void = {
            title,
            subtitle,
            body in
            NotificationSoundSettings.runCustomCommand(title: title, subtitle: subtitle, body: body)
        }
    ) {
        if effects.sound {
            NotificationSoundSettings.playSelectedSound()
        }
        if effects.command, runCommand {
            commandRunner(title, subtitle, body)
        }
    }
}
