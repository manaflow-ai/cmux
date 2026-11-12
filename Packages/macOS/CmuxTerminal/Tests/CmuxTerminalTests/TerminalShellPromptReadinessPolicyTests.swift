import Testing
@testable import CmuxTerminal

@Suite
struct TerminalShellPromptReadinessPolicyTests {
    private let integration = "/Applications/cmux.app/Contents/Resources/shell-integration"
    private let policy = TerminalShellPromptReadinessPolicy()

    @Test
    func integratedZshReportsReadiness() {
        #expect(policy.reportsPromptReadiness(
            integrationDirectory: integration, resolvedCommand: "/bin/zsh",
            hasUserGhosttyCommand: false, resolvedShell: "/bin/zsh",
            managedShellCommand: nil, environment: ["ZDOTDIR": integration], managedShellReportsPromptReadiness: true
        ))
    }

    @Test(arguments: ["zsh", "bash"])
    func ambientEnvironmentCannotInventPromptReporting(shell: String) {
        #expect(!policy.reportsPromptReadiness(
            integrationDirectory: integration, resolvedCommand: "/bin/" + shell,
            hasUserGhosttyCommand: false, resolvedShell: "/bin/" + shell,
            managedShellCommand: nil,
            environment: ["ZDOTDIR": integration, "PROMPT_COMMAND": "echo user prompt"],
            managedShellReportsPromptReadiness: false
        ))
    }

    @Test
    func disabledIntegrationNeverWaitsForPrompt() {
        #expect(!policy.reportsPromptReadiness(
            integrationDirectory: nil, resolvedCommand: "/bin/zsh",
            hasUserGhosttyCommand: false, resolvedShell: "/bin/zsh",
            managedShellCommand: nil, environment: ["ZDOTDIR": integration], managedShellReportsPromptReadiness: true
        ))
    }

    @Test
    func unreadableZshBootstrapNeverWaitsForPrompt() {
        #expect(!policy.reportsPromptReadiness(
            integrationDirectory: integration, resolvedCommand: "/bin/zsh",
            hasUserGhosttyCommand: false, resolvedShell: "/bin/zsh",
            managedShellCommand: nil, environment: [:], managedShellReportsPromptReadiness: true
        ))
    }

    @Test
    func customCommandNeverWaitsForPrompt() {
        #expect(!policy.reportsPromptReadiness(
            integrationDirectory: integration, resolvedCommand: "ssh host",
            hasUserGhosttyCommand: false, resolvedShell: "/bin/zsh",
            managedShellCommand: nil, environment: ["ZDOTDIR": integration], managedShellReportsPromptReadiness: true
        ))
        #expect(!policy.reportsPromptReadiness(
            integrationDirectory: integration, resolvedCommand: nil,
            hasUserGhosttyCommand: true, resolvedShell: "/bin/zsh",
            managedShellCommand: nil, environment: ["ZDOTDIR": integration], managedShellReportsPromptReadiness: true
        ))
    }

    @Test
    func unsupportedShellNeverWaitsForPrompt() {
        #expect(!policy.reportsPromptReadiness(
            integrationDirectory: integration, resolvedCommand: "/usr/local/bin/xonsh",
            hasUserGhosttyCommand: false, resolvedShell: "/usr/local/bin/xonsh",
            managedShellCommand: nil, environment: [:], managedShellReportsPromptReadiness: true
        ))
    }

    @Test
    func fishRequiresManagedWrapper() {
        #expect(policy.reportsPromptReadiness(
            integrationDirectory: integration, resolvedCommand: "fish-wrapper",
            hasUserGhosttyCommand: false, resolvedShell: "/opt/homebrew/bin/fish",
            managedShellCommand: "fish-wrapper", environment: [:], managedShellReportsPromptReadiness: true
        ))
        #expect(!policy.reportsPromptReadiness(
            integrationDirectory: integration, resolvedCommand: "/opt/homebrew/bin/fish",
            hasUserGhosttyCommand: false, resolvedShell: "/opt/homebrew/bin/fish",
            managedShellCommand: nil, environment: [:], managedShellReportsPromptReadiness: true
        ))
    }
}
