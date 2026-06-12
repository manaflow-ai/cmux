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

// MARK: - Generic agent hook target resolution
extension CMUXCLI {
    func resolveAccessibleWorkspaceId(_ raw: String?, ctx: GenericAgentHookContext) -> String? {
        guard let raw = nonEmptyClaudeHookIdentifier(raw) else {
            return nil
        }
        guard let candidate = try? resolveWorkspaceId(raw, client: ctx.client),
              (try? ctx.client.sendV2(method: "surface.list", params: ["workspace_id": candidate])) != nil else {
            return nil
        }
        return candidate
    }

    func resolveAccessibleSurfaceId(_ raw: String?, workspaceId: String, ctx: GenericAgentHookContext) -> String? {
        guard let raw = nonEmptyClaudeHookIdentifier(raw),
              let candidate = try? resolveSurfaceId(raw, workspaceId: workspaceId, client: ctx.client),
              let listed = try? ctx.client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId]) else {
            return nil
        }
        let items = listed["surfaces"] as? [[String: Any]] ?? []
        return items.contains(where: {
            ($0["id"] as? String) == candidate || ($0["ref"] as? String) == candidate
        }) ? candidate : nil
    }

    private func resolveDefaultSurfaceId(workspaceId: String, ctx: GenericAgentHookContext) -> String? {
        try? resolveSurfaceId(nil, workspaceId: workspaceId, client: ctx.client)
    }

    func processBinding(ctx: GenericAgentHookContext) -> CallerTerminalBinding? {
        if !ctx.didResolveProcessBinding {
            ctx.didResolveProcessBinding = true
            // Always resolve the agent process's own terminal binding (TTY first, then PID), even
            // when env supplies both ids. Historically this was suppressed whenever both env ids
            // were present, which made a leaked/stale CMUX_SURFACE_ID impossible to correct — the
            // codex jumble class, where a session routes to the wrong surface and the no-pid-gate
            // resume binding persists it across reload. resolveAgentHookTarget now uses this
            // binding to OVERRIDE a disagreeing ambient-env surface; the binding stays nil (env
            // trusted) under remote/SSH where no local TTY maps to a surface.
            ctx.processBindingCache = resolveCallerTerminalBindingByTTY(client: ctx.client)
                ?? resolveAgentProcessTerminalBinding(pid: ctx.inferredPID, client: ctx.client)
        }
        return ctx.processBindingCache
    }

#if DEBUG
    func processBindingDebugState(ctx: GenericAgentHookContext) -> String {
        guard ctx.didResolveProcessBinding else { return "deferred" }
        return ctx.processBindingCache == nil ? "nil" : "resolved"
    }
#endif

    func workspaceArg(ctx: GenericAgentHookContext) -> String? {
        ctx.resolvedDirectWorkspaceArg ?? processBinding(ctx: ctx)?.workspaceId
    }

    func resolveAgentHookTarget(
        mapped: ClaudeHookSessionRecord?,
        ctx: GenericAgentHookContext
    ) -> (workspaceId: String, surfaceId: String)? {
        guard !ctx.hasUnusableDirectBinding else {
#if DEBUG
            agentHookDebugLog(
                "agentHook.target.nil agent=\(ctx.def.name) subcommand=\(ctx.subcommand) session=\(agentHookDebugShort(ctx.sessionId)) reason=invalidDirectBinding mapped=\(mapped == nil ? 0 : 1)",
                socketPath: ctx.client.socketPath,
                env: ctx.env
            )
#endif
            return nil
        }
        func resolveTarget(
            workspaceId: String,
            preferredSurfaceId: String?,
            mapped: ClaudeHookSessionRecord?
        ) -> (workspaceId: String, surfaceId: String)? {
            if let preferredSurfaceId = nonEmptyClaudeHookIdentifier(preferredSurfaceId),
               let surfaceId = resolveAccessibleSurfaceId(preferredSurfaceId, workspaceId: workspaceId, ctx: ctx) {
                return (workspaceId, surfaceId)
            }

            if let mappedSurface = nonEmptyClaudeHookIdentifier(mapped?.surfaceId),
               let surfaceId = resolveAccessibleSurfaceId(mappedSurface, workspaceId: workspaceId, ctx: ctx) {
                return (workspaceId, surfaceId)
            }

            guard let surfaceId = resolveDefaultSurfaceId(workspaceId: workspaceId, ctx: ctx) else {
                return nil
            }
            return (workspaceId, surfaceId)
        }

        // G3 (codex jumble defense-in-depth): the surface id can arrive from the ambient env
        // (CMUX_SURFACE_ID), which a launcher or an inherited subprocess can leak as the operator's
        // FOCUSED pane rather than the agent's own pane. When the agent process's controlling TTY
        // (or PID) is bound to a DIFFERENT, accessible surface inside this same workspace, that
        // binding is ground truth — prefer it. Returns the env surface unchanged when there is no
        // env surface to correct, when it came from an explicit --surface flag (operator intent),
        // or when the TTY/PID binding is unavailable (remote/SSH) or already agrees. Stays within
        // the env workspace so a flaky binding can never cross-route to a different workspace.
        func correctedDirectSurfaceId(workspaceId: String) -> String? {
            guard let envSurface = ctx.resolvedDirectSurfaceArg else { return nil }
            guard ctx.hookWsFlag == nil, ctx.explicitSurfaceFlag == nil else { return envSurface }
            guard let binding = processBinding(ctx: ctx),
                  let boundSurfaceRaw = nonEmptyClaudeHookIdentifier(binding.surfaceId),
                  let boundWorkspaceRaw = nonEmptyClaudeHookIdentifier(binding.workspaceId),
                  resolveAccessibleWorkspaceId(boundWorkspaceRaw, ctx: ctx) == workspaceId,
                  let boundSurface = resolveAccessibleSurfaceId(boundSurfaceRaw, workspaceId: workspaceId, ctx: ctx),
                  boundSurface != envSurface else {
                return envSurface
            }
#if DEBUG
            agentHookDebugLog(
                "agentHook.surface.correct agent=\(ctx.def.name) subcommand=\(ctx.subcommand) session=\(agentHookDebugShort(ctx.sessionId)) env=\(agentHookDebugShort(envSurface)) tty=\(agentHookDebugShort(boundSurface))",
                socketPath: ctx.client.socketPath,
                env: ctx.env
            )
#endif
            return boundSurface
        }

        if let workspaceId = ctx.resolvedDirectWorkspaceArg {
            let preferredSurfaceId = correctedDirectSurfaceId(workspaceId: workspaceId)
                ?? (ctx.hookWsFlag == nil ? processBinding(ctx: ctx)?.surfaceId : nil)
            let target = resolveTarget(workspaceId: workspaceId, preferredSurfaceId: preferredSurfaceId, mapped: mapped)
#if DEBUG
            agentHookDebugLog(
                "agentHook.target.\(target == nil ? "nil" : "resolved") agent=\(ctx.def.name) subcommand=\(ctx.subcommand) session=\(agentHookDebugShort(ctx.sessionId)) source=direct workspace=\(agentHookDebugShort(target?.workspaceId ?? workspaceId)) surface=\(agentHookDebugShort(target?.surfaceId)) mapped=\(mapped == nil ? 0 : 1)",
                socketPath: ctx.client.socketPath,
                env: ctx.env
            )
#endif
            return target
        }

        let binding = processBinding(ctx: ctx)
        if let workspaceId = resolveAccessibleWorkspaceId(binding?.workspaceId, ctx: ctx),
           let target = resolveTarget(
               workspaceId: workspaceId,
               preferredSurfaceId: binding?.surfaceId,
               mapped: mapped
           ) {
#if DEBUG
            agentHookDebugLog(
                "agentHook.target.resolved agent=\(ctx.def.name) subcommand=\(ctx.subcommand) session=\(agentHookDebugShort(ctx.sessionId)) source=process workspace=\(agentHookDebugShort(target.workspaceId)) surface=\(agentHookDebugShort(target.surfaceId)) mapped=\(mapped == nil ? 0 : 1)",
                socketPath: ctx.client.socketPath,
                env: ctx.env
            )
#endif
            return target
        }

        guard let workspaceId = resolveAccessibleWorkspaceId(mapped?.workspaceId, ctx: ctx) else {
#if DEBUG
            agentHookDebugLog(
                "agentHook.target.nil agent=\(ctx.def.name) subcommand=\(ctx.subcommand) session=\(agentHookDebugShort(ctx.sessionId)) reason=noWorkspace mapped=\(mapped == nil ? 0 : 1)",
                socketPath: ctx.client.socketPath,
                env: ctx.env
            )
#endif
            return nil
        }
        let target = resolveTarget(workspaceId: workspaceId, preferredSurfaceId: nil, mapped: mapped)
#if DEBUG
        agentHookDebugLog(
            "agentHook.target.\(target == nil ? "nil" : "resolved") agent=\(ctx.def.name) subcommand=\(ctx.subcommand) session=\(agentHookDebugShort(ctx.sessionId)) source=mapped workspace=\(agentHookDebugShort(target?.workspaceId ?? workspaceId)) surface=\(agentHookDebugShort(target?.surfaceId)) mapped=\(mapped == nil ? 0 : 1)",
            socketPath: ctx.client.socketPath,
            env: ctx.env
        )
#endif
        return target
    }
}
