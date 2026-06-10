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

// MARK: - Generic agent hook shared context
extension CMUXCLI {
    /// Shared state for a single `runGenericAgentHook` invocation.
    ///
    /// Carries the locals that the per-case handlers and helper methods used to
    /// capture as nested functions inside `runGenericAgentHook`. Mutable shared
    /// locals (the lazy process-binding cache and `didSendFeedTelemetry`) become
    /// `var` properties so the original mutation semantics are preserved.
    final class GenericAgentHookContext {
        let def: AgentHookDef
        let client: SocketClient
        let telemetry: CLISocketSentryTelemetry
        let socketPassword: String?
        let env: [String: String]
        let subcommand: String
        let inferredPID: Int?
        let hookWsFlag: String?
        let explicitSurfaceFlag: String?

        // Populated by the runGenericAgentHook prologue, in the original
        // declaration order, before the per-case dispatch runs.
        var resolvedDirectWorkspaceArg: String?
        var hasInvalidDirectWorkspaceArg = false
        var resolvedDirectSurfaceArg: String?
        var hasInvalidDirectSurfaceArg = false
        var hasUnusableDirectBinding = false
        var input: ClaudeHookParsedInput!
        var store: ClaudeHookSessionStore!
        var hookCwd: String?
        var sessionId = ""
        var pidKey = ""

        // Mutable shared state (formerly mutable locals captured by the
        // nested funcs in runGenericAgentHook).
        var processBindingCache: CallerTerminalBinding?
        var didResolveProcessBinding = false
        var didSendFeedTelemetry = false

        init(
            def: AgentHookDef,
            client: SocketClient,
            telemetry: CLISocketSentryTelemetry,
            socketPassword: String?,
            env: [String: String],
            subcommand: String,
            inferredPID: Int?,
            hookWsFlag: String?,
            explicitSurfaceFlag: String?
        ) {
            self.def = def
            self.client = client
            self.telemetry = telemetry
            self.socketPassword = socketPassword
            self.env = env
            self.subcommand = subcommand
            self.inferredPID = inferredPID
            self.hookWsFlag = hookWsFlag
            self.explicitSurfaceFlag = explicitSurfaceFlag
        }
    }
}
