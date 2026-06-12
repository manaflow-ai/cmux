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

// MARK: - Generic agent hook session state helpers
extension CMUXCLI {
    // Destructive session teardown shared by a genuine (non-turn-boundary)
    // `session-end` and the dedicated `session-finalize` action: consume the
    // restore record, clear the surface resume binding, and clear PID routing.
    func performAgentSessionTeardown(ctx: GenericAgentHookContext) {
        guard let mapped = ctx.sessionId.isEmpty ? nil : (try? ctx.store.lookup(sessionId: ctx.sessionId)) else { return }
        sendAgentFeedTelemetry(workspaceId: mapped.workspaceId, ctx: ctx)
        let suppressVisibleMutations = shouldSuppressNestedAgentVisibleMutations(currentAgentPID: mapped.pid, env: ctx.env)
        if suppressVisibleMutations {
            ctx.telemetry.breadcrumb("\(ctx.def.name)-hook.session-end.nested-suppressed")
        } else if let consumed = try? ctx.store.consume(sessionId: ctx.sessionId, workspaceId: nil, surfaceId: nil) {
            clearAgentSurfaceResumeBinding(
                client: ctx.client,
                surfaceId: consumed.surfaceId,
                sessionId: consumed.sessionId
            )
            _ = try? sendV1Command(
                "clear_agent_pid \(ctx.pidKey) --tab=\(consumed.workspaceId)\(socketPanelOption(consumed.surfaceId)) --clear-status",
                client: ctx.client
            )
        }
    }

    func runtimeStatus(for notificationStatus: AgentHookNotificationStatus?) -> AgentHookRuntimeStatus? {
        switch notificationStatus {
        case .idle?:
            return .idle
        case .needsInput?:
            return .needsInput
        case .error?:
            return .error
        case nil:
            return nil
        }
    }

    func agentLifecycle(for notificationStatus: AgentHookNotificationStatus?) -> AgentHibernationLifecycleState? {
        switch notificationStatus {
        case .idle?:
            return .idle
        case .needsInput?, .error?:
            return .needsInput
        case nil:
            return nil
        }
    }

    func hasNewerRunningSession(workspaceId: String, surfaceId: String, ctx: GenericAgentHookContext) -> Bool {
        (try? ctx.store.hasRunningSession(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            excludingSessionId: ctx.sessionId,
            onlyNewerThanExcludedSession: true,
            requireLiveProcess: true
        )) == true
    }

    private func hasOtherRunningSession(workspaceId: String, ctx: GenericAgentHookContext) -> Bool {
        (try? ctx.store.hasRunningSession(
            workspaceId: workspaceId,
            surfaceId: nil,
            excludingSessionId: ctx.sessionId,
            requireLiveProcess: true
        )) == true
    }

    func setIdleStatusUnlessAnotherSessionIsRunning(workspaceId: String, surfaceId: String, ctx: GenericAgentHookContext) {
        if hasOtherRunningSession(workspaceId: workspaceId, ctx: ctx) {
#if DEBUG
            agentHookDebugLog(
                "agentHook.status.keepRunning agent=\(ctx.def.name) session=\(agentHookDebugShort(ctx.sessionId)) workspace=\(agentHookDebugShort(workspaceId)) surface=\(agentHookDebugShort(surfaceId))",
                socketPath: ctx.client.socketPath,
                env: ctx.env
            )
#endif
            return
        }
        let idleStatus = String(localized: "agent.generic.notification.status.idle", defaultValue: "Idle")
        _ = try? sendV1Command(
            "set_status \(ctx.def.statusKey) \(idleStatus) --icon=pause.circle.fill --color=#8E8E93 --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
            client: ctx.client
        )
    }
}
