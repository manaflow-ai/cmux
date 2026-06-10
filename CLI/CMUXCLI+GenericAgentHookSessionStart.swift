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

// MARK: - Generic agent hook: session-start
extension CMUXCLI {
    /// Returns true when the handler already printed the hook reply and
    /// `runGenericAgentHook` must return immediately.
    func runGenericAgentHookSessionStart(_ ctx: GenericAgentHookContext) -> Bool {
        let mapped = ctx.sessionId.isEmpty ? nil : (try? ctx.store.lookup(sessionId: ctx.sessionId))
        guard let target = resolveAgentHookTarget(mapped: mapped, ctx: ctx) else {
            ctx.didSendFeedTelemetry = true
            print("{}")
            return true
        }
        let workspaceId = target.workspaceId
        let surfaceId = target.surfaceId
        sendAgentFeedTelemetryUnlessSuppressed(workspaceId: workspaceId, ctx: ctx)
        let pid = ctx.inferredPID
        let suppressVisibleMutations = shouldSuppressNestedAgentVisibleMutations(currentAgentPID: pid, env: ctx.env)
        let launchCommand = agentLaunchCommandFromEnvironment(
            ctx.env,
            fallbackPID: pid,
            fallbackKind: ctx.def.name,
            cwd: ctx.hookCwd ?? mapped?.cwd
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
                preserveExistingTurnBaseline: true
            )
        }
        if !ctx.sessionId.isEmpty {
            try? ctx.store.upsert(
                sessionId: ctx.sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: ctx.hookCwd ?? mapped?.cwd,
                transcriptPath: ctx.input.transcriptPath ?? mapped?.transcriptPath,
                pid: pid,
                launchCommand: launchCommand,
                agentLifecycle: .unknown,
                runtimeStatus: suppressVisibleMutations ? nil : .running,
                updateRuntimeStatus: !suppressVisibleMutations
            )
            if suppressVisibleMutations {
                ctx.telemetry.breadcrumb("\(ctx.def.name)-hook.session-start.nested-suppressed")
            } else {
                try? ctx.store.clearNotificationEmission(sessionId: ctx.sessionId)
                publishAgentSurfaceResumeBinding(
                    client: ctx.client,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    kind: ctx.def.name,
                    displayName: ctx.def.displayName,
                    sessionId: ctx.sessionId,
                    cwd: ctx.hookCwd ?? mapped?.cwd,
                    launchCommand: launchCommand
                )
            }
        }
        if let pid, !suppressVisibleMutations {
            _ = try? sendV1Command(
                "set_agent_pid \(ctx.pidKey) \(pid) --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
                client: ctx.client
            )
        }
        setAgentLifecycle(
            client: ctx.client,
            key: ctx.def.statusKey,
            lifecycle: .unknown,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        return false
    }
}
