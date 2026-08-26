import CmuxNotifications
import Foundation
import UserNotifications

struct NativeNotificationDeliveryHooks: Sendable {
    typealias AuthorizationCompletion = @Sendable (Bool, NotificationAuthorizationState) -> Void
    typealias AuthorizationHandler = @Sendable (@escaping AuthorizationCompletion) -> Void
    typealias Scheduler = @Sendable (UNNotificationRequest, @escaping @Sendable (Error?) -> Void) -> Void
    typealias CommandRunner = @Sendable (String, String, String) -> Void

    typealias UnavailableFeedbackPlayer = @Sendable (TerminalNotificationPolicyEffects) -> Void

    static let defaultCommandRunner: CommandRunner = {
        title,
        subtitle,
        body in
        NotificationSoundSettings.runCustomCommand(title: title, subtitle: subtitle, body: body)
    }

    var authorizationHandlerForTesting: AuthorizationHandler?
    let userNotificationCenter: UserNotificationCenterService
    var scheduler: Scheduler?
    static let defaultUnavailableFeedbackPlayer: UnavailableFeedbackPlayer = { effects in
        NativeNotificationDeliveryHooks.playNativeUnavailableFeedback(effects: effects)
    }

    var commandRunner: CommandRunner = defaultCommandRunner
    var unavailableFeedbackPlayer: UnavailableFeedbackPlayer = defaultUnavailableFeedbackPlayer

    init(userNotificationCenter: UserNotificationCenterService) {
        self.userNotificationCenter = userNotificationCenter
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
        let scheduler = scheduler
        Task {
            let result: Result<Void, UserNotificationCenterFailure>
            if let scheduler {
                result = await userNotificationCenter.add(request, using: scheduler)
            } else {
                result = await userNotificationCenter.add(request)
            }
            switch result {
            case .success:
                completion(nil)
            case .failure(let error):
                completion(error)
            }
        }
    }

    func runCommand(title: String, subtitle: String, body: String) {
        commandRunner(title, subtitle, body)
    }

    func playUnavailableFeedback(effects: TerminalNotificationPolicyEffects) {
        unavailableFeedbackPlayer(effects)
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
