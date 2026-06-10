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


// MARK: - Generic agent hook runner
extension CMUXCLI {
    // MARK: Generic hook handler

    private func resolvedAgentHookSessionId(
        def: AgentHookDef,
        input: ClaudeHookParsedInput,
        env: [String: String],
        cwd: String?
    ) -> String {
        if let sessionId = normalizedHookValue(input.sessionId) {
            return sessionId
        }
        if def.name == "rovodev" {
            return RovoDevSessionResolver.inferredRovoDevSessionId(cwd: cwd, env: env) ?? ""
        }
        return normalizedHookValue(env["CMUX_SURFACE_ID"]) ?? ""
    }

    func runGenericAgentHook(
        def: AgentHookDef,
        commandArgs: [String],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        socketPassword: String? = nil
    ) throws {
        let env = ProcessInfo.processInfo.environment
        let subcommand = commandArgs.first?.lowercased() ?? ""
        let hookArgs = Array(commandArgs.dropFirst())
        telemetry.breadcrumb("\(def.name)-hook.\(subcommand)")

        if def.name == "codex", subcommand == "monitor" {
            try runCodexTranscriptMonitor(commandArgs: hookArgs, client: client)
            return
        }

        // Workspace/surface resolution: prefer --workspace/--surface flags,
        // then env, then the caller process. Grok strips CMUX_* from hook
        // subprocesses, so PID attribution is the only reliable live binding.
        let inferredPID = inferredAgentPID()
        let hookWsFlag = optionValue(hookArgs, name: "--workspace")
        let directWorkspaceArg = hookWsFlag ?? normalizedHookValue(env["CMUX_WORKSPACE_ID"])
        let explicitSurfaceFlag = optionValue(hookArgs, name: "--surface")
        let directSurfaceArg = explicitSurfaceFlag
            ?? (hookWsFlag == nil ? normalizedHookValue(env["CMUX_SURFACE_ID"]) : nil)

        let ctx = GenericAgentHookContext(
            def: def,
            client: client,
            telemetry: telemetry,
            socketPassword: socketPassword,
            env: env,
            subcommand: subcommand,
            inferredPID: inferredPID,
            hookWsFlag: hookWsFlag,
            explicitSurfaceFlag: explicitSurfaceFlag
        )

        ctx.resolvedDirectWorkspaceArg = resolveAccessibleWorkspaceId(directWorkspaceArg, ctx: ctx)
        // Only an EXPLICIT --workspace flag that fails to resolve is a hard, hook-dropping error. A
        // stale/invalid AMBIENT CMUX_WORKSPACE_ID must not abort routing — treated as absent, it falls
        // through to the PID/TTY binding below, which is ground truth.
        ctx.hasInvalidDirectWorkspaceArg = hookWsFlag != nil && ctx.resolvedDirectWorkspaceArg == nil
        ctx.resolvedDirectSurfaceArg = {
            guard let directSurfaceArg else { return nil }
            guard let workspaceId = ctx.resolvedDirectWorkspaceArg ?? processBinding(ctx: ctx)?.workspaceId else { return nil }
            return resolveAccessibleSurfaceId(directSurfaceArg, workspaceId: workspaceId, ctx: ctx)
        }()
        // Same asymmetry for the surface: an explicit --surface flag that fails to resolve is a hard
        // error, but a stale/invalid ambient CMUX_SURFACE_ID (a surface that was closed, or belongs to
        // another workspace) must fall through to the PID/TTY binding instead of dropping the hook —
        // that is the stale-env variant of the codex jumble.
        ctx.hasInvalidDirectSurfaceArg = explicitSurfaceFlag != nil && ctx.resolvedDirectSurfaceArg == nil
        ctx.hasUnusableDirectBinding = ctx.hasInvalidDirectWorkspaceArg || ctx.hasInvalidDirectSurfaceArg

        let rawInput = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        ctx.input = parseClaudeHookInput(rawInput: rawInput)

        ctx.store = ClaudeHookSessionStore(
            processEnv: env.merging(
                ["CMUX_CLAUDE_HOOK_STATE_PATH": agentHookStatePath(sessionStoreSuffix: def.sessionStoreSuffix, env: env)],
                uniquingKeysWith: { _, new in new }
            )
        )

        ctx.hookCwd = ctx.input.cwd
            ?? normalizedHookValue(env["CMUX_AGENT_LAUNCH_CWD"])
            ?? normalizedHookValue(env["PWD"])
        ctx.sessionId = resolvedAgentHookSessionId(def: def, input: ctx.input, env: env, cwd: ctx.hookCwd)
        let action = Self.subcommandActions[subcommand] ?? .noop
#if DEBUG
        agentHookDebugLog(
            "agentHook.start agent=\(def.name) subcommand=\(subcommand) session=\(agentHookDebugShort(ctx.sessionId)) inputSession=\(agentHookDebugShort(ctx.input.sessionId)) rawBytes=\(rawInput.utf8.count) hasCwd=\(ctx.hookCwd == nil ? 0 : 1) envWorkspace=\(env["CMUX_WORKSPACE_ID"] == nil ? 0 : 1) envSurface=\(env["CMUX_SURFACE_ID"] == nil ? 0 : 1) directWorkspace=\(directWorkspaceArg == nil ? 0 : 1) directSurface=\(directSurfaceArg == nil ? 0 : 1) invalidDirect=\(ctx.hasUnusableDirectBinding ? 1 : 0) processBinding=\(processBindingDebugState(ctx: ctx)) socketName=\(agentHookDebugSocketName(client.socketPath))",
            socketPath: client.socketPath,
            env: env
        )
#endif
        ctx.pidKey = "\(def.statusKey).\(ctx.sessionId.isEmpty ? "default" : ctx.sessionId)"

        defer {
            if !ctx.didSendFeedTelemetry, !shouldSuppressGenericFeedTelemetry(ctx: ctx) {
                sendAgentFeedTelemetry(ctx: ctx)
            }
        }

        switch action {
        case .sessionStart:
            if runGenericAgentHookSessionStart(ctx) { return }

        case .promptSubmit:
            if try runGenericAgentHookPromptSubmit(ctx) { return }

        case .stop:
            if runGenericAgentHookStop(ctx) { return }

        case .approvalResponse:
            if runGenericAgentHookApprovalResponse(ctx) { return }

        case .notification:
            if runGenericAgentHookNotification(ctx) { return }

        case .sessionEnd:
            runGenericAgentHookSessionEnd(ctx)

        case .sessionFinalize:
            performAgentSessionTeardown(ctx: ctx)

        case .noop:
            break
        }

        print("{}")
    }
}
