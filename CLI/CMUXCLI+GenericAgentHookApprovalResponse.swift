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

// MARK: - Generic agent hook: approval-response
extension CMUXCLI {
    /// Returns true when the handler already printed the hook reply and
    /// `runGenericAgentHook` must return immediately.
    func runGenericAgentHookApprovalResponse(_ ctx: GenericAgentHookContext) -> Bool {
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
        let suppressVisibleMutations = shouldSuppressNestedAgentVisibleMutations(currentAgentPID: pid, env: ctx.env)
        if !ctx.sessionId.isEmpty, !suppressVisibleMutations {
            try? ctx.store.markNotificationResolved(
                sessionId: ctx.sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: ctx.hookCwd ?? mapped?.cwd,
                transcriptPath: ctx.input.transcriptPath ?? mapped?.transcriptPath,
                pid: pid,
                launchCommand: launchCommand ?? mapped?.launchCommand,
                agentLifecycle: .running,
                runtimeStatus: .running
            )
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
            _ = try? sendV1Command(
                "set_status \(ctx.def.statusKey) \(runningStatus) --icon=bolt.fill --color=#4C8DFF --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
                client: ctx.client
            )
        } else {
            ctx.telemetry.breadcrumb("\(ctx.def.name)-hook.approval-response.nested-suppressed")
        }
        return false
    }
}
