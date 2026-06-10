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

// MARK: - Generic agent hook: stop
extension CMUXCLI {
    /// Returns true when the handler already printed the hook reply and
    /// `runGenericAgentHook` must return immediately.
    func runGenericAgentHookStop(_ ctx: GenericAgentHookContext) -> Bool {
        if ctx.def.name == "codex", !ctx.sessionId.isEmpty {
            let stopTurnId = ctx.input.turnId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stopTurnId.isEmpty {
                retireCodexMonitorLeases(sessionId: ctx.sessionId, turnId: stopTurnId, env: ctx.env)
            }
        }
        let mapped = ctx.sessionId.isEmpty ? nil : (try? ctx.store.lookup(sessionId: ctx.sessionId))
        guard let target = resolveAgentHookTarget(mapped: mapped, ctx: ctx) else {
            ctx.didSendFeedTelemetry = true
            print("{}")
            return true
        }
        let workspaceId = target.workspaceId
        let surfaceId = target.surfaceId
        sendAgentFeedTelemetry(workspaceId: workspaceId, ctx: ctx)
        let pid = mapped?.pid ?? ctx.inferredPID
        let codexFailure: CodexHookFailureSummary?
        let codexSubagentSignals: CodexTranscriptSubagentSignals
        if ctx.def.name == "codex" {
            codexFailure = summarizeCodexHookFailure(parsedInput: ctx.input, sessionId: ctx.sessionId, env: ctx.env)
            if subagentNotificationSuppressionEnabled(env: ctx.env),
               let transcriptPath = normalizedHookValue(ctx.input.transcriptPath)
                ?? findCodexTranscriptPath(sessionId: ctx.sessionId, env: ctx.env) {
                codexSubagentSignals = readCodexTranscriptSubagentSignals(
                    path: transcriptPath,
                    turnId: ctx.input.turnId
                )
            } else {
                codexSubagentSignals = CodexTranscriptSubagentSignals()
            }
        } else {
            codexFailure = nil
            codexSubagentSignals = CodexTranscriptSubagentSignals()
        }
        let antigravityFailure: AgentHookNotificationSummary? = {
            guard ctx.def.name == "antigravity", let rawObject = ctx.input.rawObject else { return nil }
            let signal = firstString(in: rawObject, keys: ["terminationReason", "reason", "type", "kind"]) ?? ""
            let message = firstString(in: rawObject, keys: ["error", "message", "description"]) ?? signal
            let summary = classifyAgentHookNotification(
                def: ctx.def,
                signal: signal,
                message: message,
                isFallback: false
            )
            return summary.status == .error ? summary : nil
        }()

        let cwd = ctx.hookCwd ?? mapped?.cwd
        let grokAssistantMessage: String? = {
            guard ctx.def.name == "grok" else { return nil }
            return latestGrokAssistantMessage(
                cwd: cwd,
                sessionId: ctx.input.sessionId ?? ctx.sessionId,
                env: ctx.env
            )
        }()
        let lastMsg = claudeAssistantMessageFromHookPayload(ctx.input.object)
        let projectName: String? = {
            guard let cwd, !cwd.isEmpty else { return nil }
            return URL(fileURLWithPath: NSString(string: cwd).expandingTildeInPath).lastPathComponent
        }()
        var subtitle = codexFailure?.subtitle ?? String(
            localized: "agent.codex.completion.subtitle.completed",
            defaultValue: "Completed"
        )
        if let antigravityFailure {
            subtitle = antigravityFailure.subtitle
        }
        if codexFailure == nil, antigravityFailure == nil, let projectName, !projectName.isEmpty {
            subtitle = String.localizedStringWithFormat(
                String(
                    localized: "agent.codex.completion.subtitle.completedInProject",
                    defaultValue: "Completed in %@"
                ),
                projectName
            )
        }
        let body = codexFailure?.body
            ?? antigravityFailure?.body
            ?? lastMsg.map { truncate(normalizedSingleLine($0), maxLength: 200) }
            ?? grokAssistantMessage.map { truncate(normalizedSingleLine($0), maxLength: 200) }
            ?? String.localizedStringWithFormat(
                String(
                    localized: "agent.codex.completion.body.sessionCompleted",
                    defaultValue: "%@ session completed"
                ),
                ctx.def.displayName
        )
        let antigravityHasActiveBackgroundWork = hasActiveAntigravityBackgroundWork(ctx: ctx)
        let stopNotificationStatus: AgentHookNotificationStatus = (codexFailure == nil && antigravityFailure == nil) ? .idle : .error
        let lifecycleAfterStop: AgentHibernationLifecycleState = {
            if antigravityHasActiveBackgroundWork && stopNotificationStatus == .idle {
                return .running
            }
            return stopNotificationStatus == .idle ? .idle : .needsInput
        }()
        let staleIdleStopHasNewerRunningSession = lifecycleAfterStop == .idle &&
            hasNewerRunningSession(workspaceId: workspaceId, surfaceId: surfaceId, ctx: ctx)
        let launchCommand = agentLaunchCommandFromEnvironment(
            ctx.env,
            fallbackPID: pid,
            fallbackKind: ctx.def.name,
            cwd: cwd
        )
        let terminalActivePromptTurnIdsForStop: Set<String>
        if !staleIdleStopHasNewerRunningSession,
           ctx.def.name == "codex",
           let incomingTurnId = normalizedHookValue(ctx.input.turnId) {
            let activePromptTurnStack = mapped?.activePromptTurnIds?
                .compactMap({ normalizedHookValue($0) }) ?? []
            let activePromptTurnId = activePromptTurnStack.last ?? normalizedHookValue(mapped?.activePromptTurnId)
            let activeTurnIds = activePromptTurnStack.isEmpty
                ? activePromptTurnId.map { [$0] } ?? []
                : activePromptTurnStack
            let activeTurnIdsToCheck = activeTurnIds.filter { $0 != incomingTurnId }
            if !activeTurnIdsToCheck.isEmpty,
               let transcriptPath = normalizedHookValue(ctx.input.transcriptPath ?? mapped?.transcriptPath)
                   ?? findCodexTranscriptPath(sessionId: ctx.sessionId, env: ctx.env) {
                terminalActivePromptTurnIdsForStop = codexTranscriptTerminalTurnIds(
                    path: transcriptPath,
                    turnIds: Set(activeTurnIdsToCheck)
                )
            } else {
                terminalActivePromptTurnIdsForStop = []
            }
        } else {
            terminalActivePromptTurnIdsForStop = []
        }
        let nestedPromptStop: Bool
        if !ctx.sessionId.isEmpty, !staleIdleStopHasNewerRunningSession {
            nestedPromptStop = (try? ctx.store.recordPromptStop(
                sessionId: ctx.sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: cwd,
                transcriptPath: ctx.input.transcriptPath ?? mapped?.transcriptPath,
                turnId: ctx.input.turnId,
                terminalActivePromptTurnIds: terminalActivePromptTurnIdsForStop,
                pid: pid,
                launchCommand: launchCommand,
                agentLifecycle: lifecycleAfterStop,
                lastSubtitle: nil,
                lastBody: nil
            )) ?? false
        } else {
            nestedPromptStop = false
        }
        let suppressVisibleMutations = shouldSuppressNestedAgentVisibleMutations(
            currentAgentPID: pid,
            nestedPromptEvent: nestedPromptStop,
            transcriptSubagentSession: codexSubagentSignals.isSubagentSession,
            env: ctx.env
        ) || staleIdleStopHasNewerRunningSession
        let suppressCompletionNotification = suppressVisibleMutations
            || codexSubagentSignals.hasSubagentNotificationRelay

        if !ctx.sessionId.isEmpty, !suppressVisibleMutations {
            try? ctx.store.upsert(sessionId: ctx.sessionId, workspaceId: workspaceId, surfaceId: surfaceId, cwd: cwd,
                                  transcriptPath: ctx.input.transcriptPath ?? mapped?.transcriptPath,
                                  pid: pid,
                                  launchCommand: launchCommand,
                                  agentLifecycle: lifecycleAfterStop,
                                  lastSubtitle: subtitle,
                                  lastBody: body,
                                  lastNotificationStatus: stopNotificationStatus,
                                  updateLastNotificationStatus: true,
                                  runtimeStatus: (antigravityHasActiveBackgroundWork && stopNotificationStatus == .idle) ? .running : runtimeStatus(for: stopNotificationStatus),
                                  updateRuntimeStatus: true)
            publishAgentSurfaceResumeBinding(
                client: ctx.client,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                kind: ctx.def.name,
                displayName: ctx.def.displayName,
                sessionId: ctx.sessionId,
                cwd: cwd,
                launchCommand: launchCommand ?? mapped?.launchCommand
            )
        }
        if let pid, !suppressVisibleMutations {
            _ = try? sendV1Command(
                "set_agent_pid \(ctx.pidKey) \(pid) --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
                client: ctx.client
            )
        }

        let notificationFingerprint = notificationDedupeFingerprint(status: stopNotificationStatus, ctx: ctx)
        let shouldPublishStopNotification = ctx.def.publishesStopNotification && (!antigravityHasActiveBackgroundWork || stopNotificationStatus == .error)
        let hasGrokTranscriptContext = ctx.def.name == "grok" && normalizedHookValue(cwd) != nil
        let shouldPublishGrokStopFallbackNotification = ctx.def.name == "grok"
            && stopNotificationStatus == .idle
            && (grokAssistantMessage != nil || !hasGrokTranscriptContext)
        let shouldPublishStopAlert = (shouldPublishStopNotification || shouldPublishGrokStopFallbackNotification)
            && !suppressCompletionNotification
        if suppressVisibleMutations {
            ctx.telemetry.breadcrumb(
                staleIdleStopHasNewerRunningSession
                    ? "\(ctx.def.name)-hook.stop.stale-idle-suppressed"
                    : "\(ctx.def.name)-hook.stop.nested-suppressed"
            )
        } else if suppressCompletionNotification {
            ctx.telemetry.breadcrumb("\(ctx.def.name)-hook.stop.subagent-notification-suppressed")
        }
        if shouldPublishStopAlert, shouldSendNotification(fingerprint: notificationFingerprint, ctx: ctx) {
            let payload = notificationPayload(title: ctx.def.displayName, subtitle: subtitle, body: body)
            let notifyCommand = "notify_target_async \(workspaceId) \(surfaceId) \(payload)"
#if DEBUG
            agentHookDebugLog(
                "agentHook.stop.notify agent=\(ctx.def.name) session=\(agentHookDebugShort(ctx.sessionId)) fallback=\(shouldPublishGrokStopFallbackNotification ? 1 : 0) workspace=\(agentHookDebugShort(workspaceId)) surface=\(agentHookDebugShort(surfaceId)) subtitleLen=\(subtitle.count) bodyLen=\(body.count)",
                socketPath: ctx.client.socketPath,
                env: ctx.env
            )
#endif
            do {
                let response = try sendV1Command(notifyCommand, client: ctx.client)
#if DEBUG
                agentHookDebugLog(
                    "agentHook.stop.notify.sent agent=\(ctx.def.name) session=\(agentHookDebugShort(ctx.sessionId)) response=\(response)",
                    socketPath: ctx.client.socketPath,
                    env: ctx.env
                )
#endif
                markNotificationSent(fingerprint: notificationFingerprint, ctx: ctx)
            } catch {
#if DEBUG
                agentHookDebugLog(
                    "agentHook.stop.notify.error agent=\(ctx.def.name) session=\(agentHookDebugShort(ctx.sessionId)) error=\(String(describing: error))",
                    socketPath: ctx.client.socketPath,
                    env: ctx.env
                )
#endif
            }
        } else if shouldPublishStopAlert {
#if DEBUG
            agentHookDebugLog(
                "agentHook.stop.notify.skipDuplicate agent=\(ctx.def.name) session=\(agentHookDebugShort(ctx.sessionId)) fallback=\(shouldPublishGrokStopFallbackNotification ? 1 : 0) fingerprint=\(agentHookDebugShort(notificationFingerprint))",
                socketPath: ctx.client.socketPath,
                env: ctx.env
            )
#endif
        }
        if !suppressVisibleMutations {
            if let codexFailure {
                setAgentLifecycle(
                    client: ctx.client,
                    key: ctx.def.statusKey,
                    lifecycle: .needsInput,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId
                )
                _ = try? sendV1Command(
                    "set_status \(ctx.def.statusKey) \(codexFailure.statusValue) --icon=exclamationmark.triangle.fill --color=#FF453A --priority=100 --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
                    client: ctx.client
                )
            } else if antigravityFailure != nil {
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
            } else if antigravityHasActiveBackgroundWork {
                setAgentLifecycle(
                    client: ctx.client,
                    key: ctx.def.statusKey,
                    lifecycle: .running,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId
                )
                let runningStatus = String(localized: "agent.generic.status.running", defaultValue: "Running")
                _ = try? sendV1Command(
                    "set_status \(ctx.def.statusKey) \(runningStatus) --icon=bolt.fill --color=#4C8DFF --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
                    client: ctx.client
                )
            } else {
                setAgentLifecycle(
                    client: ctx.client,
                    key: ctx.def.statusKey,
                    lifecycle: .idle,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId
                )
                setIdleStatusUnlessAnotherSessionIsRunning(workspaceId: workspaceId, surfaceId: surfaceId, ctx: ctx)
            }
        }
        return false
    }
}
