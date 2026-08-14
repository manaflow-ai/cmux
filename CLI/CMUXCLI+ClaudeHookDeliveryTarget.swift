// One authoritative hook-event → live pane resolution for Claude hooks.
//
// Invariant (https://github.com/manaflow-ai/cmux/issues/7939): an agent that
// finishes in pane P of workspace W gets its notification, unread ring, and
// status on exactly P in W. Live identity therefore outranks every persisted
// or spawn-time claim:
//
//   1. current-invocation agent-pid target (`agent.resolve_delivery_target
//      {pid}`) — the surface that owns the agent process RIGHT NOW; wins over a polluted
//      session record (#7391 resume/tty drift) and heals it via the caller's
//      subsequent upsert. Local direct-socket hooks only: a relay-backed
//      connection carries a remote host's pid namespace.
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
        /// Frequent events (per-tool PreToolUse) skip the pid/tty scan and
        /// rely on records healed by the turn-level hooks. This does NOT gate
        /// the cheap `{surface_id}` re-home probe: that probe only fires when
        /// the resolved surface was a non-authoritative guess, and disabling
        /// it would let a stale record mutate (and, via upsert, re-record) the
        /// wrong pane mid-turn.
        var allowsPidProbe: Bool = true
    }

    private enum LiveAgentDeliveryTargetProbeResult {
        case notAttempted
        case unsupported
        case failed
        case resolved(ClaudeHookDeliveryTarget)
    }

    func resolveClaudeHookDeliveryTarget(
        mappedSession: ClaudeHookSessionRecord?,
        routing: ClaudeHookRoutingContext,
        client: SocketClient
    ) throws -> ClaudeHookDeliveryTarget? {
        let pidProbeAllowed = routing.allowsPidProbe && routing.preferCallerTTYRouting
        let rehomeAllowed = routing.preferCallerTTYRouting
        if pidProbeAllowed {
            switch liveAgentPidDeliveryTarget(pid: routing.agentPid, client: client) {
            case .resolved(let live):
                return live
            case .failed:
                // A present resolver rejected the current invocation pid. Do
                // not promote spawn-environment identity for a fresh session:
                // only matching persisted-record + invocation surface identity
                // may be re-homed through the app's live ownership map.
                let invocationSurfaceId = nonEmptyClaudeHookIdentifier(routing.surfaceArg)
                let recordedSurfaceId = nonEmptyClaudeHookIdentifier(mappedSession?.surfaceId)
                guard let invocationSurfaceId,
                      recordedSurfaceId == invocationSurfaceId,
                      let corroborated = rehomedClaudeHookDeliveryTarget(
                          surfaceId: invocationSurfaceId,
                          claimedWorkspaceId: mappedSession?.workspaceId ?? routing.workspaceArg,
                          client: client
                      ) else { return nil }
                return corroborated
            case .notAttempted, .unsupported:
                break
            }
        }
        // Surface UUIDs are valid across a relay (unlike pids, which stay
        // host-local — that restriction lives in liveAgentPidDeliveryTarget),
        // so the surface-only re-home probe runs for relay-backed hooks too.
        // Over the restricted cloud CLI bridge the resolver method is denied
        // (`remote_cli_method_denied`), which surfaces here as `.failed` and
        // stays fail-closed exactly as before.
        if !routing.allowsPidProbe, rehomeAllowed {
            let invocationSurfaceId = nonEmptyClaudeHookIdentifier(routing.surfaceArg)
            let recordedSurfaceId = nonEmptyClaudeHookIdentifier(mappedSession?.surfaceId)
            guard let invocationSurfaceId else { return nil }
            if let recordedSurfaceId, recordedSurfaceId != invocationSurfaceId {
                guard let recordedWorkspaceId = nonEmptyClaudeHookIdentifier(mappedSession?.workspaceId),
                      !claudeHookSurfaceIsListed(
                          recordedSurfaceId,
                          workspaceId: recordedWorkspaceId,
                          client: client
                      ) else { return nil }
            }
            switch liveAgentSurfaceDeliveryTarget(
                surfaceId: invocationSurfaceId,
                claimedWorkspaceId: mappedSession?.workspaceId ?? routing.workspaceArg,
                client: client
            ) {
            case .resolved(let live):
                return live
            case .unsupported:
                // Older apps do not expose the resolver. Preserve the
                // validated legacy chain used before live re-homing existed.
                break
            case .failed, .notAttempted:
                // A present resolver rejected this invocation identity (or
                // the identity could not be formed), so stay fail-closed.
                return nil
            }
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
            guard rehomeAllowed else { return nil }
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
        // The record's workspace died (the legacy chain resolved a DIFFERENT
        // workspace than the session recorded): the record surface's current
        // owner outranks whatever the caller-tty fallback would pick, which
        // can be an unrelated pane via a stale tty row. Only if the record
        // surface is gone too does the legacy fallback proceed.
        if rehomeAllowed,
           let recordedWorkspaceId = nonEmptyClaudeHookIdentifier(mappedSession?.workspaceId),
           recordedWorkspaceId != workspaceId,
           let rehomed = rehomedClaudeHookDeliveryTarget(
               surfaceId: mappedSession?.surfaceId,
               claimedWorkspaceId: nil,
               client: client
           ) {
            return rehomed
        }
        let resolvedSurface = try resolvePreferredSurfaceForClaudeHookDetailed(
            preferred: mappedSession?.surfaceId,
            fallback: routing.surfaceArg,
            fallbackIsExplicit: routing.surfaceFlagIsExplicit,
            workspaceId: workspaceId,
            callerTerminalBinding: routing.callerTerminalBinding,
            client: client
        )
        if !resolvedSurface.isAuthoritative, rehomeAllowed {
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

    /// `{pid}` probe: only the current hook invocation's pid may be promoted
    /// to live identity. An older app may fall back; a present resolver's
    /// rejection must fail closed unless the caller supplies corroborated
    /// surface identity (handled by the caller).
    private func liveAgentPidDeliveryTarget(
        pid: Int?,
        client: SocketClient
    ) -> LiveAgentDeliveryTargetProbeResult {
        // A relay-backed connection means this hook is not running in the
        // app's process namespace (SSH/cloud host): its CMUX_CLAUDE_PID is a
        // REMOTE pid, and resolving that number against the Mac's local
        // process table could match an unrelated local process attached to
        // some other pane. Surface/workspace UUIDs are machine-independent,
        // so the legacy chain and the {surface_id} re-home probe still apply.
        guard !client.isRelayBacked, let pid, pid > 0 else { return .notAttempted }
        let payload: [String: Any]
        do {
            payload = try client.sendV2(
                method: "agent.resolve_delivery_target",
                params: ["pid": pid],
                responseTimeout: 2.0
            )
        } catch let error as CLIError where error.v2Code == "method_not_found"
                || error.v2Code == "unrecognized_method" {
            return .unsupported
        } catch {
            return .failed
        }
        guard
              (payload["source"] as? String) == "pid",
              let workspaceId = normalizedHandleValue(payload["workspace_id"] as? String),
              isUUID(workspaceId),
              let surfaceId = normalizedHandleValue(payload["surface_id"] as? String),
              isUUID(surfaceId) else {
            return .failed
        }
        return .resolved(ClaudeHookDeliveryTarget(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            isAuthoritative: true
        ))
    }

    /// `{surface_id}` probe: the workspace that CURRENTLY owns a known
    /// identity surface. Only a `source == "surface"` answer counts.
    private func rehomedClaudeHookDeliveryTarget(
        surfaceId: String?,
        claimedWorkspaceId: String?,
        client: SocketClient
    ) -> ClaudeHookDeliveryTarget? {
        guard case .resolved(let target) = liveAgentSurfaceDeliveryTarget(
            surfaceId: surfaceId,
            claimedWorkspaceId: claimedWorkspaceId,
            client: client
        ) else { return nil }
        return target
    }

    private func liveAgentSurfaceDeliveryTarget(
        surfaceId: String?,
        claimedWorkspaceId: String?,
        client: SocketClient
    ) -> LiveAgentDeliveryTargetProbeResult {
        guard let surfaceId = nonEmptyClaudeHookIdentifier(surfaceId), isUUID(surfaceId) else {
            return .notAttempted
        }
        var params: [String: Any] = ["surface_id": surfaceId]
        if let claimedWorkspaceId = nonEmptyClaudeHookIdentifier(claimedWorkspaceId), isUUID(claimedWorkspaceId) {
            params["workspace_id"] = claimedWorkspaceId
        }
        let payload: [String: Any]
        do {
            payload = try client.sendV2(
                method: "agent.resolve_delivery_target",
                params: params,
                responseTimeout: 2.0
            )
        } catch let error as CLIError where error.v2Code == "method_not_found"
                || error.v2Code == "unrecognized_method" {
            return .unsupported
        } catch {
            return .failed
        }
        guard
              (payload["source"] as? String) == "surface",
              let workspaceId = normalizedHandleValue(payload["workspace_id"] as? String),
              isUUID(workspaceId) else {
            return .failed
        }
        return .resolved(ClaudeHookDeliveryTarget(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            isAuthoritative: true
        ))
    }
}
