// One authoritative hook-event → live pane resolution for Claude hooks.
//
// Invariant (https://github.com/manaflow-ai/cmux/issues/7939): an agent that
// finishes in pane P of workspace W gets its notification, unread ring, and
// status on exactly P in W. Live identity therefore outranks every persisted
// or spawn-time claim:
//
//   1. live agent-pid target (`agent.resolve_delivery_target {pid}`) — the
//      surface that owns the agent process RIGHT NOW; wins over a polluted
//      session record (#7391 resume/tty drift) and heals it via the caller's
//      subsequent upsert.
//   2. the legacy chain (session record → caller tty → spawn env), each
//      validated against a live workspace (unchanged from #7228).
//   3. identity-surface re-home (`agent.resolve_delivery_target
//      {surface_id}`) — when the legacy chain would fall back to the resolved
//      workspace's focused surface, ask the app which workspace currently
//      owns the identity surface and deliver to that pane instead (#5781
//      pane moves; also heals a workspace listing that lags the app's panel
//      map when the owner is the same workspace).
//
// Explicit --workspace/--surface flags bypass the live probes entirely, and an
// app without the resolver method degrades to the legacy chain unchanged.

import Foundation

extension CMUXCLI {
    struct ClaudeHookDeliveryTarget {
        let workspaceId: String
        let surfaceId: String
        /// Resolved from the hook's own identity (live pid target, session
        /// record, explicit value, or caller tty) rather than the
        /// focused/first-surface fallback.
        let isAuthoritative: Bool
    }

    /// The per-invocation routing inputs shared by every Claude hook
    /// subcommand: explicit flags, spawn-time env fallbacks, the lazy caller
    /// binding, and the live agent pid.
    struct ClaudeHookRoutingContext {
        let workspaceArg: String?
        let surfaceArg: String?
        let surfaceFlagIsExplicit: Bool
        let preferCallerTTYRouting: Bool
        let callerTerminalBinding: (() -> CallerTerminalBinding?)?
        let agentPid: Int?
        /// Frequent, low-stakes events (per-tool PreToolUse) skip the live
        /// probes and rely on records healed by the turn-level hooks.
        var allowsLiveProbe: Bool = true
    }

    func resolveClaudeHookDeliveryTarget(
        mappedSession: ClaudeHookSessionRecord?,
        routing: ClaudeHookRoutingContext,
        client: SocketClient
    ) throws -> ClaudeHookDeliveryTarget? {
        let probesAllowed = routing.allowsLiveProbe && routing.preferCallerTTYRouting
        if probesAllowed,
           let live = liveAgentPidDeliveryTarget(
               pid: routing.agentPid ?? mappedSession?.pid,
               client: client
           ) {
            return live
        }
        guard let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
            preferred: mappedSession?.workspaceId,
            fallback: routing.workspaceArg,
            preferCallerTTYOverFallback: routing.preferCallerTTYRouting,
            callerTerminalBinding: routing.callerTerminalBinding,
            client: client
        ) else {
            // Every workspace claim is dead (e.g. the recorded workspace was
            // closed after its pane moved out): follow the identity surface to
            // whichever workspace owns it now, else stay a no-op.
            guard probesAllowed else { return nil }
            return rehomedClaudeHookDeliveryTarget(
                surfaceId: mappedSession?.surfaceId,
                claimedWorkspaceId: mappedSession?.workspaceId,
                client: client
            ) ?? rehomedClaudeHookDeliveryTarget(
                surfaceId: routing.surfaceArg,
                claimedWorkspaceId: routing.workspaceArg,
                client: client
            )
        }
        let resolvedSurface = try resolvePreferredSurfaceForClaudeHookDetailed(
            preferred: mappedSession?.surfaceId,
            fallback: routing.surfaceArg,
            fallbackIsExplicit: routing.surfaceFlagIsExplicit,
            workspaceId: workspaceId,
            callerTerminalBinding: routing.callerTerminalBinding,
            client: client
        )
        if !resolvedSurface.isAuthoritative, probesAllowed {
            // The legacy chain fell back to a focused-surface guess: the
            // identity surface was not in the resolved workspace's listing.
            // If the app confirms which workspace currently owns the identity
            // surface, that answer wins — whether the pane moved workspaces
            // (#5781) or the listing merely lagged the app's panel map and
            // the owner is the same workspace (a same-workspace answer still
            // outranks the focused-surface guess).
            let rehomed = rehomedClaudeHookDeliveryTarget(
                surfaceId: mappedSession?.surfaceId,
                claimedWorkspaceId: workspaceId,
                client: client
            ) ?? rehomedClaudeHookDeliveryTarget(
                surfaceId: routing.surfaceArg,
                claimedWorkspaceId: workspaceId,
                client: client
            )
            if let rehomed {
                return rehomed
            }
        }
        return ClaudeHookDeliveryTarget(
            workspaceId: workspaceId,
            surfaceId: resolvedSurface.surfaceId,
            isAuthoritative: resolvedSurface.isAuthoritative
        )
    }

    /// `{pid}` probe: only a `source == "pid"` answer counts — the app refuses
    /// to guess, and an older app (method_not_found) or a dead/remote pid
    /// falls back to the legacy chain.
    private func liveAgentPidDeliveryTarget(
        pid: Int?,
        client: SocketClient
    ) -> ClaudeHookDeliveryTarget? {
        guard let pid, pid > 0,
              let payload = try? client.sendV2(
                  method: "agent.resolve_delivery_target",
                  params: ["pid": pid],
                  responseTimeout: 2.0
              ),
              (payload["source"] as? String) == "pid",
              let workspaceId = normalizedHandleValue(payload["workspace_id"] as? String),
              isUUID(workspaceId),
              let surfaceId = normalizedHandleValue(payload["surface_id"] as? String),
              isUUID(surfaceId) else {
            return nil
        }
        return ClaudeHookDeliveryTarget(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            isAuthoritative: true
        )
    }

    /// `{surface_id}` probe: the workspace that CURRENTLY owns a known
    /// identity surface. Only a `source == "surface"` answer counts.
    private func rehomedClaudeHookDeliveryTarget(
        surfaceId: String?,
        claimedWorkspaceId: String?,
        client: SocketClient
    ) -> ClaudeHookDeliveryTarget? {
        guard let surfaceId = nonEmptyClaudeHookIdentifier(surfaceId), isUUID(surfaceId) else {
            return nil
        }
        var params: [String: Any] = ["surface_id": surfaceId]
        if let claimedWorkspaceId = nonEmptyClaudeHookIdentifier(claimedWorkspaceId), isUUID(claimedWorkspaceId) {
            params["workspace_id"] = claimedWorkspaceId
        }
        guard let payload = try? client.sendV2(
                  method: "agent.resolve_delivery_target",
                  params: params,
                  responseTimeout: 2.0
              ),
              (payload["source"] as? String) == "surface",
              let workspaceId = normalizedHandleValue(payload["workspace_id"] as? String),
              isUUID(workspaceId) else {
            return nil
        }
        return ClaudeHookDeliveryTarget(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            isAuthoritative: true
        )
    }
}
