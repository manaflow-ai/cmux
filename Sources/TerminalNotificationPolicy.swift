import AppKit
import CmuxNotifications
import Foundation

enum TerminalNotificationPolicyEngine {
    private static let maxOutputBytes = 1_048_576

    static func evaluate(
        request: TerminalNotificationPolicyRequest,
        hooks: [CmuxResolvedNotificationHook]
    ) async -> Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure> {
        let initialEnvelope = TerminalNotificationPolicyEnvelope(
            notification: TerminalNotificationPolicyPayload(
                workspaceId: request.tabId.uuidString,
                surfaceId: request.surfaceId?.uuidString,
                title: request.title,
                subtitle: request.subtitle,
                body: request.body
            ),
            context: TerminalNotificationPolicyContext(
                cwd: request.cwd,
                configPath: nil,
                hookId: nil,
                appFocused: request.isAppFocused,
                focusedPanel: request.isFocusedPanel
            )
        )

        return await evaluate(envelope: initialEnvelope, hooks: hooks)
    }

    static func evaluate(
        envelope initialEnvelope: TerminalNotificationPolicyEnvelope,
        hooks: [CmuxResolvedNotificationHook]
    ) async -> Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure> {
        guard !hooks.isEmpty else {
            return .success(initialEnvelope)
        }

        var envelope = initialEnvelope
        for hook in hooks {
            envelope.context.cwd = hook.cwd
            envelope.context.configPath = hook.sourcePath
            envelope.context.hookId = hook.id
            switch await run(hook: hook, envelope: envelope) {
            case .success(let nextEnvelope):
                envelope = nextEnvelope
                if envelope.stop == true {
                    return .success(envelope)
                }
            case .failure(let failure):
                return .failure(failure)
            }
        }
        return .success(envelope)
    }

    private static func run(
        hook: CmuxResolvedNotificationHook,
        envelope: TerminalNotificationPolicyEnvelope
    ) async -> Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure> {
        let inputData: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            inputData = try encoder.encode(envelope)
        } catch {
            return .failure(failure(hook: hook, message: "Could not encode notification policy input: \(error.localizedDescription)"))
        }

        return await NotificationHookProcessRun(
            cwd: hook.cwd,
            command: hook.command,
            timeoutSeconds: hook.timeoutSeconds,
            hookId: hook.id,
            sourcePath: hook.sourcePath,
            envelope: envelope,
            inputData: inputData,
            maxOutputBytes: maxOutputBytes
        ).run()
    }

    fileprivate static func failure(
        hook: CmuxResolvedNotificationHook,
        message: String
    ) -> TerminalNotificationPolicyFailure {
        TerminalNotificationPolicyFailure(
            hookId: hook.id,
            sourcePath: hook.sourcePath,
            message: message
        )
    }
}
