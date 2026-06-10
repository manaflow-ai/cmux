import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

// MARK: - Generic agent hook: notification
extension CMUXCLI {
    /// Returns true when the handler already printed the hook reply and
    /// `runGenericAgentHook` must return immediately.
    func runGenericAgentHookNotification(_ ctx: GenericAgentHookContext) -> Bool {
        let mapped = ctx.sessionId.isEmpty ? nil : (try? ctx.store.lookup(sessionId: ctx.sessionId))
        guard let target = resolveAgentHookTarget(mapped: mapped, ctx: ctx) else {
            ctx.didSendFeedTelemetry = true
            print("{}")
            return true
        }
        let workspaceId = target.workspaceId
        let surfaceId = target.surfaceId

        let notificationCwd = ctx.hookCwd ?? mapped?.cwd
#if DEBUG
        agentHookDebugLog(
            "agentHook.notification.target agent=\(ctx.def.name) session=\(agentHookDebugShort(ctx.sessionId)) workspace=\(agentHookDebugShort(workspaceId)) surface=\(agentHookDebugShort(surfaceId)) mapped=\(mapped == nil ? 0 : 1) hasCwd=\(notificationCwd == nil ? 0 : 1)",
            socketPath: ctx.client.socketPath,
            env: ctx.env
        )
#endif
        if ctx.def.name == "grok",
           let notificationMessage = normalizedAgentHookNotificationMessage(parsedInput: ctx.input) {
            if isGrokInternalSessionNotification(notificationMessage) {
#if DEBUG
                agentHookDebugLog(
                    "agentHook.notification.skip agent=\(ctx.def.name) session=\(agentHookDebugShort(ctx.sessionId)) reason=internalSessionNotification messageLen=\(notificationMessage.count)",
                    socketPath: ctx.client.socketPath,
                    env: ctx.env
                )
#endif
                print("{}")
                return true
            }
        }

        var summary = summarizeAgentHookNotification(
            def: ctx.def,
            parsedInput: ctx.input,
            cwd: notificationCwd,
            env: ctx.env,
            sessionId: ctx.input.sessionId ?? ctx.sessionId
        )
        if summary.isFallback, let savedBody = mapped?.lastBody, !savedBody.isEmpty {
            summary = AgentHookNotificationSummary(
                subtitle: mapped?.lastSubtitle ?? summary.subtitle,
                body: savedBody,
                status: mapped?.lastNotificationStatus,
                isFallback: false
            )
        }
        let antigravitySuppressDuplicateIdleWhileBackgroundWork = ctx.def.name == "antigravity"
            && summary.status == .idle
            && mapped?.runtimeStatus == .running
            && mapped?.lastNotificationStatus == .idle
            && hasActiveAntigravityBackgroundWork(ctx: ctx)

#if DEBUG
        agentHookDebugLog(
            "agentHook.notification.summary agent=\(ctx.def.name) session=\(agentHookDebugShort(ctx.sessionId)) status=\(summary.status?.rawValue ?? "nil") fallback=\(summary.isFallback ? 1 : 0) subtitleLen=\(summary.subtitle.count) bodyLen=\(summary.body.count)",
            socketPath: ctx.client.socketPath,
            env: ctx.env
        )
#endif

        if ctx.def.name == "grok", summary.status == nil {
#if DEBUG
            agentHookDebugLog(
                "agentHook.notification.skip agent=\(ctx.def.name) session=\(agentHookDebugShort(ctx.sessionId)) reason=nonTerminalNotification subtitleLen=\(summary.subtitle.count) bodyLen=\(summary.body.count)",
                socketPath: ctx.client.socketPath,
                env: ctx.env
            )
#endif
            print("{}")
            return true
        }

        if antigravitySuppressDuplicateIdleWhileBackgroundWork {
#if DEBUG
            agentHookDebugLog(
                "agentHook.notification.skip agent=\(ctx.def.name) session=\(agentHookDebugShort(ctx.sessionId)) reason=backgroundWorkIdleDuplicate",
                socketPath: ctx.client.socketPath,
                env: ctx.env
            )
#endif
            sendAgentFeedTelemetryUnlessSuppressed(workspaceId: workspaceId, ctx: ctx)
            print("{}")
            return true
        }

        let staleIdleNotificationHasNewerRunningSession = summary.status == .idle &&
            hasNewerRunningSession(workspaceId: workspaceId, surfaceId: surfaceId, ctx: ctx)
        if staleIdleNotificationHasNewerRunningSession {
#if DEBUG
            agentHookDebugLog(
                "agentHook.notification.skip agent=\(ctx.def.name) session=\(agentHookDebugShort(ctx.sessionId)) reason=staleIdleNewerRunning workspace=\(agentHookDebugShort(workspaceId)) surface=\(agentHookDebugShort(surfaceId))",
                socketPath: ctx.client.socketPath,
                env: ctx.env
            )
#endif
            sendAgentFeedTelemetryUnlessSuppressed(workspaceId: workspaceId, ctx: ctx)
            print("{}")
            return true
        }

        if !ctx.sessionId.isEmpty {
            let pid = mapped?.pid ?? ctx.inferredPID
            let launchCommand = agentLaunchCommandFromEnvironment(
                ctx.env,
                fallbackPID: pid,
                fallbackKind: ctx.def.name,
                cwd: ctx.hookCwd ?? mapped?.cwd
            )
            let lifecycle = agentLifecycle(for: summary.status)
            // These agents use completion notifications as turn boundaries;
            // keep the route but close nested prompt depth.
            if (ctx.def.name == "grok" || ctx.def.name == "antigravity"),
               summary.status == .idle || summary.status == .error {
                _ = try? ctx.store.recordPromptStop(
                    sessionId: ctx.sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: notificationCwd,
                    transcriptPath: ctx.input.transcriptPath ?? mapped?.transcriptPath,
                    pid: pid,
                    launchCommand: launchCommand,
                    agentLifecycle: lifecycle,
                    lastSubtitle: summary.subtitle,
                    lastBody: summary.body,
                    lastNotificationStatus: summary.status,
                    updateLastNotificationStatus: true,
                    runtimeStatus: runtimeStatus(for: summary.status),
                    updateRuntimeStatus: true
                )
            } else {
                try? ctx.store.upsert(
                    sessionId: ctx.sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: notificationCwd,
                    transcriptPath: ctx.input.transcriptPath ?? mapped?.transcriptPath,
                    pid: pid,
                    launchCommand: launchCommand,
                    agentLifecycle: lifecycle,
                    lastSubtitle: summary.subtitle,
                    lastBody: summary.body,
                    lastNotificationStatus: summary.status,
                    updateLastNotificationStatus: true,
                    runtimeStatus: runtimeStatus(for: summary.status),
                    updateRuntimeStatus: summary.status != nil
                )
            }
        }

        let notificationFingerprint = notificationDedupeFingerprint(status: summary.status, ctx: ctx)
        if shouldSendNotification(fingerprint: notificationFingerprint, ctx: ctx) {
            let payload = notificationPayload(title: ctx.def.displayName, subtitle: summary.subtitle, body: summary.body)
            let notifyCommand = "notify_target_async \(workspaceId) \(surfaceId) \(payload)"
#if DEBUG
            agentHookDebugLog(
                "agentHook.notification.notify agent=\(ctx.def.name) session=\(agentHookDebugShort(ctx.sessionId)) workspace=\(agentHookDebugShort(workspaceId)) surface=\(agentHookDebugShort(surfaceId))",
                socketPath: ctx.client.socketPath,
                env: ctx.env
            )
#endif
            do {
                let response = try sendV1Command(notifyCommand, client: ctx.client)
#if DEBUG
                agentHookDebugLog(
                    "agentHook.notification.notify.sent agent=\(ctx.def.name) session=\(agentHookDebugShort(ctx.sessionId)) response=\(response)",
                    socketPath: ctx.client.socketPath,
                    env: ctx.env
                )
#endif
                markNotificationSent(fingerprint: notificationFingerprint, ctx: ctx)
            } catch {
#if DEBUG
                agentHookDebugLog(
                    "agentHook.notification.notify.error agent=\(ctx.def.name) session=\(agentHookDebugShort(ctx.sessionId)) error=\(String(describing: error))",
                    socketPath: ctx.client.socketPath,
                    env: ctx.env
                )
#endif
            }
        } else {
#if DEBUG
            agentHookDebugLog(
                "agentHook.notification.notify.skipDuplicate agent=\(ctx.def.name) session=\(agentHookDebugShort(ctx.sessionId)) fingerprint=\(agentHookDebugShort(notificationFingerprint))",
                socketPath: ctx.client.socketPath,
                env: ctx.env
            )
#endif
        }

        switch summary.status {
        case .needsInput?:
            setAgentLifecycle(
                client: ctx.client,
                key: ctx.def.statusKey,
                lifecycle: .needsInput,
                workspaceId: workspaceId,
                surfaceId: surfaceId
            )
            let statusValue = String.localizedStringWithFormat(
                String(localized: "agent.generic.notification.status.needsInput", defaultValue: "%@ needs input"),
                ctx.def.displayName
            )
            _ = try? sendV1Command(
                "set_status \(ctx.def.statusKey) \(statusValue) --icon=bell.fill --color=#4C8DFF --priority=100 --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
                client: ctx.client
            )
        case .error?:
            setAgentLifecycle(
                client: ctx.client,
                key: ctx.def.statusKey,
                lifecycle: .needsInput,
                workspaceId: workspaceId,
                surfaceId: surfaceId
            )
            let statusValue = String.localizedStringWithFormat(
                String(localized: "agent.generic.notification.status.error", defaultValue: "%@ error"),
                ctx.def.displayName
            )
            _ = try? sendV1Command(
                "set_status \(ctx.def.statusKey) \(statusValue) --icon=exclamationmark.triangle.fill --color=#FF453A --priority=100 --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
                client: ctx.client
            )
        case .idle?:
            if !hasNewerRunningSession(workspaceId: workspaceId, surfaceId: surfaceId, ctx: ctx) {
                setAgentLifecycle(
                    client: ctx.client,
                    key: ctx.def.statusKey,
                    lifecycle: .idle,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId
                )
            }
            setIdleStatusUnlessAnotherSessionIsRunning(workspaceId: workspaceId, surfaceId: surfaceId, ctx: ctx)
        case nil:
            break
        }
        sendAgentFeedTelemetryUnlessSuppressed(workspaceId: workspaceId, ctx: ctx)
        return false
    }
}
