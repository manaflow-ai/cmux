import CmuxNotifications
import CmuxSettings
import Foundation
import UserNotifications

struct NativeNotificationDeliveryHooks: Sendable {
    typealias AuthorizationCompletion = @MainActor @Sendable (
        Bool,
        NotificationAuthorizationState
    ) -> Void
    typealias AuthorizationHandler = @Sendable (@escaping AuthorizationCompletion) -> Void
    typealias Scheduler = @Sendable (UNNotificationRequest, @escaping @Sendable (Error?) -> Void) -> Void
    typealias CommandRunner = @Sendable (String, String, String) -> Void

    typealias UnavailableFeedbackPlayer = @Sendable (
        TerminalNotificationPolicyEffects,
        NotificationSoundOverrideContext?
    ) async -> Void

    static let defaultCommandRunner: CommandRunner = {
        title,
        subtitle,
        body in
        NotificationSoundSettings.runCustomCommand(title: title, subtitle: subtitle, body: body)
    }

    var authorizationHandlerForTesting: AuthorizationHandler?
    let userNotificationCenter: UserNotificationCenterService
    var scheduler: Scheduler?
    static let defaultUnavailableFeedbackPlayer: UnavailableFeedbackPlayer = { effects, soundContext in
        await NativeNotificationDeliveryHooks.playNativeUnavailableFeedback(
            effects: effects,
            soundContext: soundContext
        )
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

    func playUnavailableFeedback(
        effects: TerminalNotificationPolicyEffects,
        soundContext: NotificationSoundOverrideContext? = nil
    ) async {
        await unavailableFeedbackPlayer(effects, soundContext)
    }

    func runLocalFeedback(
        title: String,
        subtitle: String,
        body: String,
        effects: TerminalNotificationPolicyEffects,
        runCommand: Bool = true,
        soundContext: NotificationSoundOverrideContext? = nil
    ) async {
        await Self.runLocalFeedback(
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
    ) async {
        guard !Task.isCancelled else { return }
        if effects.sound {
            _ = await NotificationSoundSettings.playSelectedSound(context: soundContext)
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
    ) async {
        guard !Task.isCancelled else { return }
        if effects.sound {
            // Keep command hooks responsive while the sound is staged, but
            // retain the playback in this structured child task so callers
            // can await completion and tests never race a detached task.
            async let didPlay = NotificationSoundSettings.playSelectedSound(
                context: soundContext
            )
            if !Task.isCancelled, effects.command, runCommand {
                commandRunner(title, subtitle, body)
            }
            _ = await didPlay
        } else if effects.command, runCommand {
            commandRunner(title, subtitle, body)
        }
    }
}
