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


// MARK: - Agent launch command and resume bindings
extension CMUXCLI {
    func agentLaunchCommandFromEnvironment(
        _ env: [String: String],
        fallbackPID: Int?,
        fallbackKind: String,
        cwd: String?
    ) -> AgentHookLaunchCommandRecord? {
        let envArguments = decodeNULSeparatedBase64(env["CMUX_AGENT_LAUNCH_ARGV_B64"])
        let processArguments = fallbackPID.flatMap { self.processArguments(for: pid_t($0)) }
        let arguments = envArguments ?? processArguments
        let launcher = normalizedHookValue(env["CMUX_AGENT_LAUNCH_KIND"]) ?? fallbackKind
        let workingDirectory = normalizedHookValue(env["CMUX_AGENT_LAUNCH_CWD"])
            ?? normalizedHookValue(cwd)
            ?? normalizedHookValue(env["PWD"])
        let environment = selectedAgentLaunchEnvironment(from: env, kind: launcher)

        // Fallback when the launch argv is genuinely UNAVAILABLE: plain `codex` with no cmux launcher
        // (no CMUX_AGENT_LAUNCH_ARGV_B64) and an unresolved/exited PID, so processArguments returns nil.
        // The argv is gone, but the agent's launch env may still carry a non-default home that
        // resume/fork MUST reproduce or the session won't be found — above all CODEX_HOME when codex
        // runs under the subrouter account manager (~/.codex-accounts/<account>), also CLAUDE_CONFIG_DIR
        // for Claude. AgentResumeCommandBuilder then prefixes it ahead of the kind's fallback verb
        // (`CODEX_HOME=<home> codex resume <id>`), while launcher/kind resolution still gates whether a
        // resume command is produced (omx/omc and unknown kinds stay non-resumable). Empty selected env
        // keeps the historical nil. This deliberately does NOT cover a captured-but-rejected argv (see
        // the sanitizer guard below), so non-restorable invocations stay non-resumable.
        func environmentOnlyRecord() -> AgentHookLaunchCommandRecord? {
            guard !environment.isEmpty else { return nil }
            return AgentHookLaunchCommandRecord(
                launcher: launcher,
                executablePath: nil,
                arguments: [],
                workingDirectory: workingDirectory,
                environment: environment,
                capturedAt: Date().timeIntervalSince1970,
                source: "environment"
            )
        }

        guard let arguments, !arguments.isEmpty else {
            return environmentOnlyRecord()
        }

        let executablePath = normalizedHookValue(env["CMUX_AGENT_LAUNCH_EXECUTABLE"]) ?? arguments.first
        guard let sanitizedArguments = sanitizedAgentLaunchArguments(
            arguments,
            launcher: launcher,
            fallbackKind: fallbackKind
        ) else {
            // Argv WAS captured but the sanitizer rejected it — this is exactly how AgentLaunchSanitizer
            // suppresses non-restorable invocations (`codex exec`, `codex review`, `claude config`, …).
            // Those must never get a resume/fork binding, so stay nil even when a safe env var (e.g.
            // CODEX_HOME) is present; do NOT fall through to the env-only record here.
            return nil
        }
        let source = envArguments == nil ? "process" : "environment"

        return AgentHookLaunchCommandRecord(
            launcher: launcher,
            executablePath: executablePath,
            arguments: sanitizedArguments,
            workingDirectory: workingDirectory,
            environment: environment.isEmpty ? nil : environment,
            capturedAt: Date().timeIntervalSince1970,
            source: source
        )
    }

    func publishAgentSurfaceResumeBinding(
        client: SocketClient,
        workspaceId: String,
        surfaceId: String,
        kind: String,
        displayName: String,
        sessionId: String,
        cwd: String?,
        launchCommand: AgentHookLaunchCommandRecord?
    ) {
        let resumeEnvironment = agentSurfaceResumeEnvironment(kind: kind, environment: launchCommand?.environment)
        // Pin the resume binding to the directory the agent was *launched* in, not the drift-prone
        // runtime cwd: cwd-namespaced agents (Claude, Grok, Gemini, …) file their session under the
        // launch dir, so resuming from a worktree the agent later `cd`'d into fails with "No
        // conversation found".
        let resumeWorkingDirectory = AgentResumeWorkingDirectory().resolve(
            kind: kind,
            runtimeCwd: cwd,
            launchWorkingDirectory: launchCommand?.workingDirectory
        )
        guard let command = agentSurfaceResumeCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: resumeWorkingDirectory,
            environment: resumeEnvironment
        ) else {
            clearAgentSurfaceResumeBinding(
                client: client,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                sessionId: sessionId
            )
            return
        }
        var params: [String: Any] = [
            "surface_id": surfaceId,
            "name": displayName,
            "kind": kind,
            "checkpoint_id": sessionId,
            "source": "agent-hook",
            "command": command,
            "auto_resume": true
        ]
        if let resumeWorkingDirectory {
            params["cwd"] = resumeWorkingDirectory
        }
        if let resumeEnvironment, !resumeEnvironment.isEmpty {
            params["environment"] = resumeEnvironment
        }
        _ = try? client.sendV2(method: "surface.resume.set", params: params)
    }

    func clearAgentSurfaceResumeBinding(
        client: SocketClient,
        workspaceId: String,
        surfaceId: String,
        sessionId: String?
    ) {
        let normalizedSessionId = normalizedHookValue(sessionId)
        var params: [String: Any] = [
            "surface_id": surfaceId,
            "source": "agent-hook"
        ]
        if let normalizedSessionId {
            params["checkpoint_id"] = normalizedSessionId
        }
        _ = try? client.sendV2(method: "surface.resume.clear", params: params)
    }

    private func agentSurfaceResumeCommand(
        kind: String,
        sessionId: String,
        launchCommand: AgentHookLaunchCommandRecord?,
        workingDirectory: String?,
        environment: [String: String]?
    ) -> String? {
        let normalizedSessionId = normalizedHookValue(sessionId)
        guard let normalizedSessionId else { return nil }

        let argv: [String]?
        switch AgentResumeArgv().launcherResolution(
            launcher: launchCommand?.launcher,
            sessionId: normalizedSessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? []
        ) {
        case .resolved(let resolved):
            argv = resolved
        case .passthrough:
            argv = AgentResumeArgv().builtInKind(
                kind: kind,
                sessionId: normalizedSessionId,
                executablePath: launchCommand?.executablePath,
                arguments: launchCommand?.arguments ?? []
            )
        }

        guard let argv, !argv.isEmpty else { return nil }
        return agentSurfaceResumeShellCommand(
            argv: argv,
            workingDirectory: workingDirectory ?? launchCommand?.workingDirectory,
            kind: kind,
            environment: environment
        )
    }

    private func agentSurfaceResumeShellCommand(
        argv: [String],
        workingDirectory: String?,
        kind: String,
        environment: [String: String]?
    ) -> String {
        var commandParts: [String] = []
        commandParts.append(contentsOf: argv)

        let cwd = normalizedHookValue(workingDirectory)
        let sanitizedCommandParts = AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
            from: commandParts,
            workingDirectory: cwd
        )
        let resumeCommandParts = kind == "hermes-agent"
            ? hermesAgentArgumentsByReplacingOpenAICodexProvider(sanitizedCommandParts)
            : sanitizedCommandParts
        var command = resumeCommandParts.map(cliShellQuote).joined(separator: " ")
        if kind == "hermes-agent" {
            command = hermesAgentSubrouterResumeCommand(
                command,
                arguments: resumeCommandParts,
                environment: environment
            )
        }
        if let cwd {
            let quotedCwd = cliShellQuote(cwd)
            return "{ cd -- \(quotedCwd) 2>/dev/null || [ ! -d \(quotedCwd) ]; } && \(command)"
        }
        return command
    }

    private func hermesAgentSubrouterResumeCommand(
        _ command: String,
        arguments: [String],
        environment: [String: String]?
    ) -> String {
        guard !hermesAgentArgumentsSetModelAPIMode(arguments),
              hermesAgentArgumentsAllowCodexBootstrap(arguments),
              let environment,
              let baseURL = normalizedHookValue(environment[HermesAgentCodexEnvironment.customBaseURLEnvironmentKey]) else {
            return command
        }
        let hermesExecutable = normalizedHookValue(arguments.first) ?? "hermes"

        var bootstrap = [
            "\(cliShellQuote(hermesExecutable)) config set model.provider \(cliShellQuote(HermesAgentCodexEnvironment.defaultProvider)) >/dev/null",
            "\(cliShellQuote(hermesExecutable)) config set model.base_url \(cliShellQuote(baseURL)) >/dev/null",
            "\(cliShellQuote(hermesExecutable)) config set model.api_mode \(cliShellQuote(HermesAgentCodexEnvironment.codexResponsesAPIMode)) >/dev/null"
        ]
        if let model = HermesAgentCodexEnvironment.defaultCodexModel(
            environment: environment,
            ambientEnvironment: ProcessInfo.processInfo.environment
        ) {
            bootstrap.append("\(cliShellQuote(hermesExecutable)) config set model.default \(cliShellQuote(model)) >/dev/null")
        }
        return bootstrap.joined(separator: " && ") + " && " + command
    }

    private func hermesAgentArgumentsByReplacingOpenAICodexProvider(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--provider", index + 1 < arguments.count {
                result.append(argument)
                let provider = arguments[index + 1]
                result.append(provider == "openai-codex" ? HermesAgentCodexEnvironment.defaultProvider : provider)
                index += 2
                continue
            }
            if argument == "--provider=openai-codex" {
                result.append("--provider=\(HermesAgentCodexEnvironment.defaultProvider)")
            } else {
                result.append(argument)
            }
            index += 1
        }
        return result
    }

    private func hermesAgentArgumentsSetModelAPIMode(_ arguments: [String]) -> Bool {
        arguments.contains { $0.contains("model.api_mode") }
    }

    private func hermesAgentArgumentsAllowCodexBootstrap(_ arguments: [String]) -> Bool {
        guard let provider = hermesAgentProviderArgument(arguments) else {
            return true
        }
        return provider == HermesAgentCodexEnvironment.defaultProvider || provider == "openai-codex"
    }

    private func hermesAgentProviderArgument(_ arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--provider", index + 1 < arguments.count {
                return arguments[index + 1]
            }
            if argument.hasPrefix("--provider=") {
                return String(argument.dropFirst("--provider=".count))
            }
            index += 1
        }
        return nil
    }

    private func agentSurfaceResumeEnvironment(
        kind: String,
        environment: [String: String]?
    ) -> [String: String]? {
        guard let environment else { return nil }
        let selected = selectedAgentLaunchEnvironment(from: environment, kind: kind)
        guard !selected.isEmpty else { return nil }

        let claudeAuthKeys: Set<String> = [
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_MODEL",
            "ANTHROPIC_SMALL_FAST_MODEL",
            "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX",
            "CLAUDE_CONFIG_DIR"
        ]
        var resolved = selected
        if kind == "claude" {
            let preservedClaudeKeys = selected.keys.sorted().filter { claudeAuthKeys.contains($0) }
            if !preservedClaudeKeys.isEmpty {
                for key in preservedClaudeKeys {
                    resolved.removeValue(forKey: key)
                }
                resolved["CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV"] = "1"
                resolved["CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS"] = preservedClaudeKeys.joined(separator: ",")
            }
        }
        return resolved
    }

    private func decodeNULSeparatedBase64(_ rawValue: String?) -> [String]? {
        guard let rawValue = normalizedHookValue(rawValue),
              let data = Data(base64Encoded: rawValue) else {
            return nil
        }
        var parts: [String] = []
        var start = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0 {
                guard let value = String(data: data[start..<index], encoding: .utf8) else {
                    return nil
                }
                parts.append(value)
                start = data.index(after: index)
            }
            index = data.index(after: index)
        }
        if start < data.endIndex {
            guard let value = String(data: data[start..<data.endIndex], encoding: .utf8) else {
                return nil
            }
            parts.append(value)
        }
        return parts.isEmpty ? nil : parts
    }

    private func selectedAgentLaunchEnvironment(from env: [String: String], kind: String? = nil) -> [String: String] {
        var selected = AgentLaunchEnvironmentPolicy.selectedEnvironment(from: env, kind: kind)
        if kind == "hermes-agent" {
            selected = HermesAgentCodexEnvironment.applyingDefaultCodexBaseURL(
                to: selected,
                ambientEnvironment: env
            )
        }
        return selected
    }

    func normalizedHookValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    func agentHookStatePath(sessionStoreSuffix: String, env: [String: String]) -> String {
        let filename = "\(sessionStoreSuffix)-hook-sessions.json"
        guard let overrideDirectory = normalizedHookValue(env["CMUX_AGENT_HOOK_STATE_DIR"]) else {
            return "~/.cmuxterm/\(filename)"
        }
        return URL(fileURLWithPath: NSString(string: overrideDirectory).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
            .path
    }

    private func sanitizedAgentLaunchArguments(
        _ arguments: [String],
        launcher: String,
        fallbackKind: String
    ) -> [String]? {
        AgentLaunchSanitizer.sanitizedLaunchArguments(
            arguments,
            launcher: launcher,
            fallbackKind: fallbackKind
        )
    }

}
