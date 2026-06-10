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

// MARK: - Generic agent hook: prompt-submit
extension CMUXCLI {
    /// Returns true when the handler already printed the hook reply and
    /// `runGenericAgentHook` must return immediately.
    func runGenericAgentHookPromptSubmit(_ ctx: GenericAgentHookContext) throws -> Bool {
        let mapped = ctx.sessionId.isEmpty ? nil : (try? ctx.store.lookup(sessionId: ctx.sessionId))
        guard let target = resolveAgentHookTarget(mapped: mapped, ctx: ctx) else {
            ctx.didSendFeedTelemetry = true
            print("{}")
            return true
        }
        let workspaceId = target.workspaceId
        let surfaceId = target.surfaceId
        sendAgentFeedTelemetryUnlessSuppressed(workspaceId: workspaceId, ctx: ctx)
        let pid = mapped?.pid ?? ctx.inferredPID
        let launchCommand = agentLaunchCommandFromEnvironment(
            ctx.env,
            fallbackPID: pid,
            fallbackKind: ctx.def.name,
            cwd: ctx.hookCwd ?? mapped?.cwd
        )
        let transcriptPathForStore = ctx.input.transcriptPath ?? mapped?.transcriptPath
        let activePromptTurnStack = mapped?.activePromptTurnIds?
            .compactMap({ normalizedHookValue($0) }) ?? []
        let activePromptTurnId = activePromptTurnStack.last ?? normalizedHookValue(mapped?.activePromptTurnId)
        let activePromptDepth = max(mapped?.activePromptDepth ?? 0, activePromptTurnStack.count)
        let terminalActivePromptTurnIds: Set<String>
        let previousActivePromptTurnIsTerminal: Bool
        if ctx.def.name == "codex",
           let incomingTurnId = normalizedHookValue(ctx.input.turnId),
           let activeTurnId = activePromptTurnId,
           activeTurnId != incomingTurnId,
           let transcriptPath = normalizedHookValue(transcriptPathForStore)
               ?? findCodexTranscriptPath(sessionId: ctx.sessionId, env: ctx.env) {
            let activeTurnIds = activePromptTurnStack.isEmpty ? [activeTurnId] : activePromptTurnStack
            terminalActivePromptTurnIds = codexTranscriptTerminalTurnIds(
                path: transcriptPath,
                turnIds: Set(activeTurnIds)
            )
            previousActivePromptTurnIsTerminal = terminalActivePromptTurnIds.contains(activeTurnId)
        } else {
            terminalActivePromptTurnIds = []
            previousActivePromptTurnIsTerminal = false
        }
        let nestedPromptSubmit: Bool
        if !ctx.sessionId.isEmpty {
            nestedPromptSubmit = (try? ctx.store.recordPromptSubmit(
                sessionId: ctx.sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: ctx.hookCwd ?? mapped?.cwd,
                transcriptPath: transcriptPathForStore,
                turnId: ctx.input.turnId,
                previousActivePromptTurnIsTerminal: previousActivePromptTurnIsTerminal,
                terminalActivePromptTurnIds: terminalActivePromptTurnIds,
                pid: pid,
                launchCommand: launchCommand,
                agentLifecycle: .running
            )) ?? false
        } else {
            nestedPromptSubmit = false
        }
        let suppressVisibleMutations = shouldSuppressNestedAgentVisibleMutations(
            currentAgentPID: pid,
            nestedPromptEvent: nestedPromptSubmit,
            env: ctx.env
        )
        if !suppressVisibleMutations {
            try? recordAgentTurnDiffBaseline(
                agent: ctx.def.name,
                sessionId: ctx.sessionId,
                turnId: ctx.input.turnId,
                cwd: ctx.hookCwd ?? mapped?.cwd,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                env: ctx.env,
                preserveExistingTurnBaseline: activePromptDepth > 0 &&
                    (normalizedHookValue(ctx.input.turnId).map { $0 == activePromptTurnId } ?? false)
            )
        }
        if !ctx.sessionId.isEmpty, !suppressVisibleMutations {
            try? ctx.store.upsert(
                sessionId: ctx.sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: ctx.hookCwd ?? mapped?.cwd,
                transcriptPath: ctx.input.transcriptPath ?? mapped?.transcriptPath,
                pid: pid,
                launchCommand: launchCommand,
                agentLifecycle: .running,
                runtimeStatus: .running,
                updateRuntimeStatus: true
            )
            try? ctx.store.clearNotificationEmission(sessionId: ctx.sessionId)
            publishAgentSurfaceResumeBinding(
                client: ctx.client,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                kind: ctx.def.name,
                displayName: ctx.def.displayName,
                sessionId: ctx.sessionId,
                cwd: ctx.hookCwd ?? mapped?.cwd,
                launchCommand: launchCommand ?? mapped?.launchCommand
            )
        }
        if let pid, !suppressVisibleMutations {
            _ = try? sendV1Command(
                "set_agent_pid \(ctx.pidKey) \(pid) --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
                client: ctx.client
            )
        }
        if !suppressVisibleMutations {
            setAgentLifecycle(
                client: ctx.client,
                key: ctx.def.statusKey,
                lifecycle: .running,
                workspaceId: workspaceId,
                surfaceId: surfaceId
            )
            _ = try? sendV1Command(
                "clear_notifications --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
                client: ctx.client
            )
            let runningStatus = String(localized: "agent.generic.status.running", defaultValue: "Running")
            _ = try sendV1Command(
                "set_status \(ctx.def.statusKey) \(runningStatus) --icon=bolt.fill --color=#4C8DFF --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
                client: ctx.client
            )
        } else {
            ctx.telemetry.breadcrumb("\(ctx.def.name)-hook.prompt-submit.nested-suppressed")
        }
        if ctx.def.name == "codex", !ctx.sessionId.isEmpty, !suppressVisibleMutations {
            let leasePath = createCodexMonitorLease(
                sessionId: ctx.sessionId,
                turnId: ctx.input.turnId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                env: ctx.env
            )
            if leasePath == nil {
                ctx.telemetry.breadcrumb(
                    "codex-hook.monitor.lease-unavailable",
                    data: ["has_turn_id": normalizedHookValue(ctx.input.turnId) != nil]
                )
            } else {
                retireCodexMonitorLeases(
                    sessionId: ctx.sessionId,
                    turnId: nil,
                    preservingLeasePath: leasePath,
                    env: ctx.env
                )
            }
            startCodexTranscriptMonitor(
                sessionId: ctx.sessionId,
                turnId: ctx.input.turnId,
                transcriptPath: normalizedHookValue(ctx.input.transcriptPath),
                cwd: ctx.hookCwd ?? mapped?.cwd,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                leasePath: leasePath,
                env: ctx.env,
                telemetry: ctx.telemetry
            )
        }
        return false
    }
}
