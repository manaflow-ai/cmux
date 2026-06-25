import CmuxCore
import Foundation
import UserNotifications

struct NativeNotificationDeliveryHooks: Sendable {
    typealias AuthorizationCompletion = @Sendable (Bool, NotificationAuthorizationState) -> Void
    typealias AuthorizationHandler = @Sendable (@escaping AuthorizationCompletion) -> Void
    typealias Scheduler = @Sendable (UNNotificationRequest, @escaping @Sendable (Error?) -> Void) -> Void
    typealias CommandRunner = @Sendable (String, String, String) -> Void

    var authorizationHandlerForTesting: AuthorizationHandler?
    var scheduler: Scheduler = {
        request,
        completion in
        UNUserNotificationCenter.current().add(request, withCompletionHandler: completion)
    }
    var commandRunner: CommandRunner = {
        title,
        subtitle,
        body in
        NotificationSoundSettings.runCustomCommand(title: title, subtitle: subtitle, body: body)
    }

    func authorizeForTesting(_ completion: @escaping AuthorizationCompletion) -> Bool {
        guard let authorizationHandlerForTesting else {
            return false
        }
        authorizationHandlerForTesting(completion)
        return true
    }

    func schedule(
        _ request: UNNotificationRequest,
        completion: @escaping @Sendable (Error?) -> Void
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
        commandRunner: CommandRunner = {
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
