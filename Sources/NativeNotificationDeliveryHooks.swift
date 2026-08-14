import CmuxNotifications
import CmuxSettings
import Foundation
import UserNotifications

struct NativeNotificationDeliveryHooks: Sendable {
    typealias AuthorizationCompletion = @Sendable (Bool, NotificationAuthorizationState) -> Void
    typealias AuthorizationHandler = @Sendable (@escaping AuthorizationCompletion) -> Void
    typealias Scheduler = @Sendable (UNNotificationRequest, @escaping @Sendable (Error?) -> Void) -> Void
    typealias CommandRunner = @Sendable (String, String, String) -> Void

    typealias UnavailableFeedbackPlayer = @Sendable (TerminalNotificationPolicyEffects) -> Void
    typealias ContextualUnavailableFeedbackPlayer = @Sendable (
        TerminalNotificationPolicyEffects,
        NotificationSoundOverrideContext?
    ) -> Void

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
    var contextualUnavailableFeedbackPlayer: ContextualUnavailableFeedbackPlayer? = nil

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

    func playUnavailableFeedback(
        effects: TerminalNotificationPolicyEffects,
        soundContext: NotificationSoundOverrideContext? = nil
    ) {
        if let contextualUnavailableFeedbackPlayer {
            contextualUnavailableFeedbackPlayer(effects, soundContext)
        } else if soundContext != nil {
            Self.playNativeUnavailableFeedback(effects: effects, soundContext: soundContext)
        } else {
            unavailableFeedbackPlayer(effects)
        }
    }

    func runLocalFeedback(
        title: String,
        subtitle: String,
        body: String,
        effects: TerminalNotificationPolicyEffects,
        runCommand: Bool = true,
        soundContext: NotificationSoundOverrideContext? = nil
    ) {
        Self.runLocalFeedback(
            title: title,
            subtitle: subtitle,
            body: body,
            effects: effects,
            runCommand: runCommand,
            soundContext: soundContext,
            commandRunner: commandRunner
        )
    }

    static func playNativeUnavailableFeedback(
        effects: TerminalNotificationPolicyEffects,
        soundContext: NotificationSoundOverrideContext? = nil
    ) {
        if effects.sound {
            NotificationSoundSettings.playSelectedSound(context: soundContext)
        }
    }

    static func runLocalFeedback(
        title: String,
        subtitle: String,
        body: String,
        effects: TerminalNotificationPolicyEffects,
        runCommand: Bool = true,
        soundContext: NotificationSoundOverrideContext? = nil,
        commandRunner: CommandRunner = {
            title,
            subtitle,
            body in
            NotificationSoundSettings.runCustomCommand(title: title, subtitle: subtitle, body: body)
        }
    ) {
        if effects.sound {
            NotificationSoundSettings.playSelectedSound(context: soundContext)
        }
        if effects.command, runCommand {
            commandRunner(title, subtitle, body)
        }
    }
}
