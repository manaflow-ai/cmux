import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("WorkspaceSessionRestorePolicyService")
struct WorkspaceSessionRestorePolicyServiceTests {
    // Test-only holder mutated by one synchronous injected @Sendable closure.
    private final class ApprovalObservation: @unchecked Sendable {
        var url: URL?
        var secret: Data?
    }

    private struct FakeBinding: WorkspaceSurfaceResumeBinding, Equatable {
        var source: String?
        var kind: String?
        var command: String
        var cwd: String?
        var environment: [String: String]?
        var isProcessDetected: Bool
        var isAgentHookBinding: Bool
        var allowsAutomaticResume: Bool
        var requiresPromptApproval: Bool
        var autoResume: Bool?
        var usesLocalRestoreVerb: Bool
        var startupInputPrefix = "input"

        init(
            source: String? = "cli",
            kind: String? = nil,
            command: String = "echo ok",
            cwd: String? = nil,
            environment: [String: String]? = nil,
            isProcessDetected: Bool = false,
            isAgentHookBinding: Bool = false,
            allowsAutomaticResume: Bool = true,
            requiresPromptApproval: Bool = false,
            autoResume: Bool? = nil,
            usesLocalRestoreVerb: Bool = true
        ) {
            self.source = source
            self.kind = kind
            self.command = command
            self.cwd = cwd
            self.environment = environment
            self.isProcessDetected = isProcessDetected
            self.isAgentHookBinding = isAgentHookBinding
            self.allowsAutomaticResume = allowsAutomaticResume
            self.requiresPromptApproval = requiresPromptApproval
            self.autoResume = autoResume
            self.usesLocalRestoreVerb = usesLocalRestoreVerb
        }

        func restoreStartupInput() -> String? {
            "\(startupInputPrefix):\(command)"
        }
    }

    private struct FakeTerminalSnapshot: WorkspaceSessionRemoteRestoreTerminalSnapshot {
        var isRemoteTerminal: Bool?
        var remotePTYSessionID: String?
    }

    private struct FakePanelSnapshot: WorkspaceSessionRemoteRestorePanelSnapshot {
        var terminal: FakeTerminalSnapshot?
    }

    private struct FakeRemoteSnapshot: WorkspaceSessionRemoteRestoreSnapshot {
        var panels: [FakePanelSnapshot]
    }

    private func makeService(
        applyStoredApproval: @escaping @Sendable (FakeBinding, URL, Data?) -> FakeBinding? = { binding, _, _ in binding },
        shouldRunPromptedSurfaceResume: @escaping @Sendable (FakeBinding) -> Bool = { _ in false },
        isRunningUnderAutomatedTests: @escaping @Sendable () -> Bool = { false },
        truncateScrollback: @escaping @Sendable (String?) -> String? = { $0 },
        applyingDefaultCodexBaseURL: @escaping @Sendable ([String: String]) -> [String: String] = { $0 },
        resolvingDefaultCodexModel: @escaping @Sendable ([String: String]) -> String? = { _ in nil }
    ) -> WorkspaceSessionRestorePolicyService<FakeBinding> {
        WorkspaceSessionRestorePolicyService(
            applyStoredApproval: applyStoredApproval,
            shouldRunPromptedSurfaceResume: shouldRunPromptedSurfaceResume,
            isRunningUnderAutomatedTests: isRunningUnderAutomatedTests,
            truncateScrollback: truncateScrollback,
            hermesCodexEnvironment: WorkspaceHermesCodexEnvironment(
                customBaseURLEnvironmentKey: "OPENAI_BASE_URL",
                defaultProvider: "codex",
                codexResponsesAPIMode: "responses",
                applyingDefaultCodexBaseURL: applyingDefaultCodexBaseURL,
                resolvingDefaultCodexModel: resolvingDefaultCodexModel
            )
        )
    }

    @Test("stored approval is injected and can authorize a binding")
    func storedApprovalAuthorizesBinding() {
        let approvalURL = URL(fileURLWithPath: "/tmp/cmux-approvals.json", isDirectory: false)
        let observation = ApprovalObservation()
        let service = makeService(
            applyStoredApproval: { binding, fileURL, signingSecret in
                observation.url = fileURL
                observation.secret = signingSecret
                var copy = binding
                copy.allowsAutomaticResume = true
                return copy
            }
        )

        let result = service.surfaceResumeStartupInput(
            FakeBinding(allowsAutomaticResume: false),
            autoResumeAgentSessions: true,
            approvalStoreURL: approvalURL,
            approvalSigningSecret: Data("secret".utf8)
        )

        #expect(result == "input:echo ok")
        #expect(observation.url == approvalURL)
        #expect(observation.secret == Data("secret".utf8))
    }

    @Test("pending stored approval prevents launch")
    func pendingStoredApprovalPreventsLaunch() {
        let service = makeService(
            applyStoredApproval: { _, _, _ in nil }
        )

        let result = service.surfaceResumeStartupInput(
            FakeBinding(allowsAutomaticResume: true),
            autoResumeAgentSessions: true,
            approvalStoreURL: URL(fileURLWithPath: "/tmp/cmux-approvals.json")
        )

        #expect(result == nil)
    }

    @Test("prompt approval uses the injected prompt decision")
    func promptApprovalUsesInjectedDecision() {
        let denied = makeService(shouldRunPromptedSurfaceResume: { _ in false })
        let approved = makeService(shouldRunPromptedSurfaceResume: { _ in true })
        let binding = FakeBinding(allowsAutomaticResume: false, requiresPromptApproval: true)
        let approvalURL = URL(fileURLWithPath: "/tmp/cmux-approvals.json", isDirectory: false)

        #expect(denied.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            approvalStoreURL: approvalURL
        ) == nil)
        #expect(approved.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            approvalStoreURL: approvalURL
        ) == "input:echo ok")
        #expect(approved.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            promptForApproval: false,
            approvalStoreURL: approvalURL
        ) == nil)
    }

    @Test("agent hook bindings respect the auto-resume gate")
    func agentHookBindingsRespectAutoResumeGate() {
        let service = makeService()
        let binding = FakeBinding(
            source: "agent-hook",
            command: "claude --resume",
            isAgentHookBinding: true,
            allowsAutomaticResume: true
        )
        let approvalURL = URL(fileURLWithPath: "/tmp/cmux-approvals.json", isDirectory: false)

        #expect(service.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: false,
            approvalStoreURL: approvalURL
        ) == nil)
        #expect(service.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            approvalStoreURL: approvalURL
        ) == "input:claude --resume")
    }

    @Test("post-start launch uses the binding restore input")
    func postStartLaunchUsesBindingRestoreInput() throws {
        let service = makeService()
        let launch = try #require(service.surfaceResumeStartupLaunch(
            forApprovedBinding: FakeBinding()
        ))

        #expect(launch.initialInput == "input:echo ok")
    }

    @Test("Hermes agent bindings receive Codex bootstrap and provider rewrite")
    func hermesAgentBindingsReceiveCodexBootstrap() throws {
        let service = makeService(
            applyingDefaultCodexBaseURL: { environment in
                var copy = environment
                copy["OPENAI_BASE_URL"] = "https://codex.example.test"
                return copy
            },
            resolvingDefaultCodexModel: { _ in "gpt-5" }
        )
        let binding = FakeBinding(
            source: "agent-hook",
            kind: "hermes-agent",
            command: "cd /repo && hermes --provider openai-codex run",
            isAgentHookBinding: true,
            allowsAutomaticResume: true,
            usesLocalRestoreVerb: false
        )

        let launch = try #require(service.surfaceResumeStartupLaunch(
            binding,
            autoResumeAgentSessions: true,
            approvalStoreURL: URL(fileURLWithPath: "/tmp/cmux-approvals.json", isDirectory: false)
        ))
        let input = launch.initialInput

        #expect(input.hasPrefix("input:cd /repo && "))
        #expect(input.contains("'hermes' config set model.provider 'codex' >/dev/null"))
        #expect(input.contains("'hermes' config set model.base_url 'https://codex.example.test' >/dev/null"))
        #expect(input.contains("'hermes' config set model.api_mode 'responses' >/dev/null"))
        #expect(input.contains("'hermes' config set model.default 'gpt-5' >/dev/null"))
        #expect(input.contains("hermes --provider 'codex' run"))
    }

    @Test("local Hermes bindings stay untouched behind the restore verb")
    func localHermesBindingsSkipShellBootstrap() throws {
        let service = makeService()
        let command = "cd /repo && hermes --provider openai-codex run"
        let binding = FakeBinding(
            source: "agent-hook",
            kind: "hermes-agent",
            command: command,
            isAgentHookBinding: true,
            allowsAutomaticResume: true,
            usesLocalRestoreVerb: true
        )

        let launch = try #require(service.surfaceResumeStartupLaunch(
            binding,
            autoResumeAgentSessions: true,
            approvalStoreURL: URL(fileURLWithPath: "/tmp/cmux-approvals.json")
        ))

        #expect(launch.initialInput == "input:\(command)")
        #expect(launch.initialInput.contains("config set") == false)
    }

    @Test("compatibility-shell preparation refreshes local legacy Hermes bindings")
    func compatibilityShellPreparationRefreshesLocalLegacyHermesBindings() {
        let service = makeService(
            applyingDefaultCodexBaseURL: { environment in
                var copy = environment
                copy["OPENAI_BASE_URL"] = "https://codex.example.test"
                return copy
            },
            resolvingDefaultCodexModel: { _ in "gpt-5" }
        )
        let binding = FakeBinding(
            source: "agent-hook",
            kind: "hermes-agent",
            command: "cd /repo && hermes --provider openai-codex run",
            isAgentHookBinding: true,
            allowsAutomaticResume: true,
            usesLocalRestoreVerb: true
        )

        let compatibilityBinding = service.bindingForCompatibilityShellRestore(binding)

        #expect(compatibilityBinding.command.contains(
            "'hermes' config set model.provider 'codex' >/dev/null"
        ))
        #expect(compatibilityBinding.command.contains(
            "'hermes' config set model.base_url 'https://codex.example.test' >/dev/null"
        ))
        #expect(compatibilityBinding.command.contains(
            "'hermes' config set model.api_mode 'responses' >/dev/null"
        ))
        #expect(compatibilityBinding.command.contains(
            "'hermes' config set model.default 'gpt-5' >/dev/null"
        ))
        #expect(compatibilityBinding.command.contains("hermes --provider 'codex' run"))
    }

    @Test("remote reconnect waits when restored terminals can authenticate")
    func remoteReconnectWaitsWhenTerminalsAuthenticate() {
        let service = makeService()
        let approvalTerminal = FakePanelSnapshot(
            terminal: FakeTerminalSnapshot(isRemoteTerminal: true, remotePTYSessionID: nil)
        )
        let ptyTerminal = FakePanelSnapshot(
            terminal: FakeTerminalSnapshot(isRemoteTerminal: false, remotePTYSessionID: "pty-1")
        )

        #expect(service.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: nil,
            snapshot: FakeRemoteSnapshot(panels: [approvalTerminal])
        ))
        #expect(!service.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: "token",
            snapshot: FakeRemoteSnapshot(panels: [approvalTerminal])
        ))
        #expect(!service.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: "token",
            snapshot: FakeRemoteSnapshot(panels: [ptyTerminal])
        ))
        #expect(service.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: "token",
            snapshot: FakeRemoteSnapshot(panels: [])
        ))
        #expect(!service.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: nil,
            snapshot: FakeRemoteSnapshot(panels: []),
            isRunningUnderAutomatedTests: true
        ))
    }

    @Test("scrollback resolution prefers captured text and gates fallback")
    func scrollbackResolutionPrefersCapturedTextAndGatesFallback() {
        let service = makeService(truncateScrollback: { text in
            text.map { String($0.prefix(5)) }
        })

        #expect(service.resolvedSnapshotTerminalScrollback(
            capturedScrollback: "captured",
            fallbackScrollback: "fallback"
        ) == "captu")
        #expect(service.resolvedSnapshotTerminalScrollback(
            capturedScrollback: nil,
            fallbackScrollback: "fallback"
        ) == "fallb")
        #expect(service.resolvedSnapshotTerminalScrollback(
            capturedScrollback: nil,
            fallbackScrollback: "fallback",
            allowFallbackScrollback: false
        ) == nil)
    }

    @Test("scrollback replay skips restorable agents, OMX HUD, and resume startup work")
    func scrollbackReplayPolicy() {
        let service = makeService()

        #expect(service.shouldReplaySessionScrollback(hasRestorableAgent: false))
        #expect(!service.shouldReplaySessionScrollback(hasRestorableAgent: true))
        #expect(!service.shouldReplaySessionScrollback(
            hasRestorableAgent: false,
            tmuxStartCommand: "oh-my-codex hud"
        ))
        #expect(!service.shouldReplaySessionScrollback(
            hasRestorableAgent: false,
            hasResumeStartupWork: true
        ))
    }

    @Test("tmux start command is restorable only for OMX HUD commands")
    func restorableTmuxStartCommandRequiresOmxHud() {
        let service = makeService()

        #expect(service.restorableTmuxStartCommand("  oh-my-codex hud  ") == "oh-my-codex hud")
        #expect(service.restorableTmuxStartCommand("omx run") == nil)
        #expect(service.restorableTmuxStartCommand("hudson omx") == nil)
        #expect(service.restorableTmuxStartCommand("omx hud") == "omx hud")
    }

    @Test("cmux-generated local tmux attach commands are restorable")
    func restorableTmuxStartCommandAcceptsLocalTmuxMarker() {
        let service = makeService()
        let command = "TMUX= CMUX_LOCAL_TMUX=1 exec '/usr/local/bin/tmux' -S '/tmp/.cmux/local-tmux/server.sock' attach-session -t 'work'"

        #expect(service.restorableTmuxStartCommand(command) == command)
        #expect(service.localTmuxStartCommand(command) == command)
        #expect(service.restorableTmuxStartCommand("CMUX_LOCAL_TMUX=1 exec tmux attach -t work") == nil)
    }

    @Test("local tmux restore rejects shell substitutions in persisted commands")
    func localTmuxRestoreRejectsShellSubstitution() {
        let service = makeService()
        let command = "TMUX= CMUX_LOCAL_TMUX=1 exec '/usr/local/bin/tmux' -S /tmp/.cmux/local-tmux/$(touch${IFS}/tmp/pwn)/server.sock attach-session -t 'work'"

        #expect(service.localTmuxStartCommand(command) == nil)
    }
}
