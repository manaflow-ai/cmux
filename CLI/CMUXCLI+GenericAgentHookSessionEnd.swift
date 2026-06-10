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

// MARK: - Generic agent hook: session-end
extension CMUXCLI {
    /// Always falls through to the trailing `print("{}")` in
    /// `runGenericAgentHook` (the original case had no early-exit path; its
    /// turn-boundary `break` out of the switch becomes a `return` here).
    func runGenericAgentHookSessionEnd(_ ctx: GenericAgentHookContext) {
        if ctx.def.name == "codex", !ctx.sessionId.isEmpty {
            retireCodexMonitorLeases(sessionId: ctx.sessionId, turnId: nil, env: ctx.env)
        }
        if ctx.def.sessionEndIsTurnBoundary {
            if let mapped = ctx.sessionId.isEmpty ? nil : (try? ctx.store.lookup(sessionId: ctx.sessionId)) {
                sendAgentFeedTelemetry(workspaceId: mapped.workspaceId, ctx: ctx)
                _ = try? ctx.store.recordPromptStop(
                    sessionId: ctx.sessionId,
                    workspaceId: mapped.workspaceId,
                    surfaceId: mapped.surfaceId,
                    cwd: ctx.hookCwd ?? mapped.cwd,
                    transcriptPath: ctx.input.transcriptPath ?? mapped.transcriptPath,
                    pid: mapped.pid,
                    launchCommand: mapped.launchCommand,
                    lastSubtitle: nil,
                    lastBody: nil
                )
            }
#if DEBUG
            agentHookDebugLog(
                "agentHook.sessionEnd.keep agent=\(ctx.def.name) session=\(agentHookDebugShort(ctx.sessionId)) reason=turnBoundary",
                socketPath: ctx.client.socketPath,
                env: ctx.env
            )
#endif
            return
        }
        // A non-turn-boundary session-end is a genuine teardown.
        performAgentSessionTeardown(ctx: ctx)
    }
}
