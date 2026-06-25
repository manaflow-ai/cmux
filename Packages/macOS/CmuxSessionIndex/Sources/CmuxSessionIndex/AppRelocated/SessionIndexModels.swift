import CMUXAgentLaunch
import CmuxFoundation
import CmuxSessionIndex
import Foundation

// MARK: - Lifted value-model family

// The pure value-model family for the session index now lives in the
// CmuxSessionIndex package. These typealiases keep the ~11 app consumers
// byte-identical while the declarations and pure logic live in the package.
public typealias RegisteredSessionAgent = CmuxSessionIndex.RegisteredSessionAgent
public typealias SessionAgent = CmuxSessionIndex.SessionAgent
public typealias PullRequestLink = CmuxSessionIndex.PullRequestLink
public typealias AgentSpecifics = CmuxSessionIndex.AgentSpecifics
public typealias SessionEntry = CmuxSessionIndex.SessionEntry

// `ClaudeConfigurationRoot` was a caseless static-method namespace; it became a
// constructor-injected `struct` (FileManager injected at init) in CmuxSessionIndex.
public typealias ClaudeConfigurationRoot = CmuxSessionIndex.ClaudeConfigurationRoot

// `OpenCodeDatabaseSnapshot` moved to CMUXAgentLaunch (value type + `make(prefix:)`).

// MARK: - App-side SessionEntry extensions

// These members stay app-side because they reach app-only seams: `displayTitle`
// binds `String(localized:)` against the app bundle (a package call would silently
// drop non-English translations), and the resume-command rendering routes the
// Hermes case through the app-side `SessionEntry.hermesResumeCommand` builder
// (defined in HermesAgentIndex.swift).
extension SessionEntry {
    /// Shell command that resumes this session in a new terminal, with the agent's
    /// known per-session settings injected as CLI flags.
    var resumeCommand: String? {
        resumeCommandWithCwd
    }

    /// Shell command that resumes this session after guarding the launch directory.
    var resumeCommandWithCwd: String? {
        guard let command = resumeCommandWithoutWorkingDirectory else { return nil }
        guard let cwd = resumeWorkingDirectory else {
            return command
        }
        return "cd \(Self.shellQuote(cwd)) && \(command)"
    }

    private var resumeCommandWithoutWorkingDirectory: String? {
        switch specifics {
        case let .claude(model, permissionMode, configDirectoryForResume):
            // Route through the wrapper shim token so a manually-resumed claude session
            // re-injects cmux hooks even when the command runs in a shell where the
            // integration's PATH shim / `claude()` function are not active (e.g. the
            // `$SHELL -lic` restore launcher). The token is POSIX-only and this command
            // is typed into — and copy-pasted into — the user's own shell (fish/csh
            // included), so the rendered command is wrapped in `/bin/sh -c '…'` to parse
            // everywhere; the `cd` guard stays outside in `resumeCommandWithCwd`.
            // https://github.com/manaflow-ai/cmux/issues/5639
            var parts = ["\(AgentResumeArgv.claudeWrapperShellExecutableToken) --resume \(sessionId)"]
            if let model, !model.isEmpty {
                parts.append("--model \(Self.shellQuote(model))")
            }
            if let permissionMode, !permissionMode.isEmpty {
                parts.append("--permission-mode \(Self.shellQuote(permissionMode))")
            }
            let environment = configDirectoryForResume.map {
                ["CLAUDE_CONFIG_DIR": $0, "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV": "1", "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS": "CLAUDE_CONFIG_DIR"]
            } ?? [:]
            return AgentResumeArgv.portableClaudeResumeShellCommand(
                posixCommand: Self.withShellEnvironment(environment, command: parts.joined(separator: " "))
            )
        case let .codex(model, approval, sandbox, effort):
            var parts = ["codex resume \(sessionId)"]
            if let model, !model.isEmpty {
                parts.append("-m \(Self.shellQuote(model))")
            }
            parts.append(contentsOf: Self.codexApprovalSandboxArguments(
                approvalPolicy: approval,
                sandboxMode: sandbox
            ))
            if let effort, !effort.isEmpty {
                parts.append("-c model_reasoning_effort=\(Self.shellQuote(effort))")
            }
            return parts.joined(separator: " ")
        case let .grok(model, permissionMode, sandboxMode, grokHome):
            var argv = ["grok", "-r", sessionId]
            if let model, !model.isEmpty {
                argv.append(contentsOf: ["-m", model])
            }
            if let permissionMode, !permissionMode.isEmpty {
                argv.append(contentsOf: ["--permission-mode", permissionMode])
            }
            if let sandboxMode, !sandboxMode.isEmpty {
                argv.append(contentsOf: ["--sandbox", sandboxMode])
            }
            let environment = grokHome.flatMap { value -> [String: String]? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : ["GROK_HOME": trimmed]
            } ?? [:]
            return Self.singleQuotedShellCommand(environment: environment, argv: argv)
        case let .opencode(providerModel, agentName):
            var parts = ["opencode --session \(sessionId)"]
            if let providerModel, !providerModel.isEmpty {
                parts.append("-m \(Self.shellQuote(providerModel))")
            }
            if let agentName, !agentName.isEmpty {
                parts.append("--agent \(Self.shellQuote(agentName))")
            }
            return parts.joined(separator: " ")
        case .rovodev:
            return "acli rovodev run --restore \(Self.shellQuote(sessionId))"
        case let .hermesAgent(source, model, hermesHome):
            return Self.hermesResumeCommand(
                sessionId: sessionId,
                source: source,
                model: model,
                hermesHome: hermesHome
            )
        case .registered(let registration):
            if let command = AgentResumeCommandBuilder.resumeShellCommand(
                kind: .custom(registration.id),
                sessionId: sessionId,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: registration.id,
                    executablePath: nil,
                    arguments: [registration.defaultExecutable],
                    workingDirectory: resumeWorkingDirectory,
                    environment: nil,
                    capturedAt: nil,
                    source: "vault"
                ),
                workingDirectory: resumeWorkingDirectory,
                registrationOverride: registration,
                includeWorkingDirectoryPrefix: false
            ) {
                return command
            }
            return nil
        }
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if agent == .claude {
            if let title = Self.claudeDisplayTitle(from: trimmed) {
                return title
            }
            if Self.isClaudeLocalCommandEnvelope(trimmed) {
                return String(localized: "sessionIndex.localCommand", defaultValue: "Local command")
            }
            if Self.isClaudeSyntheticEnvelope(trimmed) {
                return String(localized: "sessionIndex.untitled", defaultValue: "Untitled chat")
            }
        }
        if trimmed.isEmpty {
            return String(localized: "sessionIndex.untitled", defaultValue: "Untitled chat")
        }
        return trimmed
    }
}
