import CmuxTerminal
import Foundation
import Testing

@Suite("Terminal shell startup policy")
struct TerminalShellStartupPolicyTests {
    private let policy = TerminalShellStartupPolicy()

    @Test("declarative startup resolves the configured mode when no owner suppresses it")
    func declarativeStartupIsAllowed() {
        let resolution = TerminalShellStartupPolicy.resolve(
            configuredMode: .nonLogin,
            hasExplicitCommand: false,
            hasExplicitInput: false,
            hasGhosttyCommand: false,
            isRestoreSurface: false,
            isManualSurface: false
        )
        #expect(resolution.allowsDeclarativeShellStartup)
        #expect(resolution.mode == .nonLogin)
    }

    @Test(arguments: [
        (true, false, false, false, false, false),
        (false, true, false, false, false, false),
        (false, false, true, false, false, false),
        (false, false, false, true, false, false),
        (false, false, false, false, true, false),
        (false, false, false, false, false, true),
    ])
    func startupOwnersSuppressDeclarativeMode(
        explicitCommand: Bool,
        explicitInput: Bool,
        ghosttyCommand: Bool,
        restore: Bool,
        manual: Bool,
        managedIntegration: Bool
    ) {
        let resolution = TerminalShellStartupPolicy.resolve(
            configuredMode: .nonLogin,
            hasExplicitCommand: explicitCommand,
            hasExplicitInput: explicitInput,
            hasGhosttyCommand: ghosttyCommand,
            isRestoreSurface: restore,
            isManualSurface: manual,
            hasManagedShellIntegration: managedIntegration
        )
        #expect(!resolution.allowsDeclarativeShellStartup)
        #expect(resolution.mode == .login)
    }

    @Test func nonLoginModeUsesInteractiveShellOverride() {
        let result = policy.commandOverride(
            shell: "/bin/zsh",
            configuration: .init(mode: .nonLogin),
            hasExplicitCommand: false,
            hasExplicitInput: false,
            hasGhosttyCommand: false,
            isRestoreSurface: false,
            isManualSurface: false
        )
        #expect(result == "/usr/bin/env '/bin/zsh' -i")
    }

    @Test func nonLoginModeNormalizesTheResolvedShellPath() {
        let result = policy.commandOverride(
            shell: "  /bin/zsh\n",
            configuration: .init(mode: .nonLogin),
            hasExplicitCommand: false,
            hasExplicitInput: false,
            hasGhosttyCommand: false,
            isRestoreSurface: false,
            isManualSurface: false
        )
        #expect(result == "/usr/bin/env '/bin/zsh' -i")
    }

    @Test func blankResolvedShellFailsClosed() {
        let result = policy.commandOverride(
            shell: " \n ",
            configuration: .init(mode: .nonLogin),
            hasExplicitCommand: false,
            hasExplicitInput: false,
            hasGhosttyCommand: false,
            isRestoreSurface: false,
            isManualSurface: false
        )
        #expect(result == nil)
    }

    @Test func loginModeLeavesGhosttyCommandUnchanged() {
        let result = policy.commandOverride(
            shell: "/bin/zsh",
            configuration: .init(mode: .login),
            hasExplicitCommand: false,
            hasExplicitInput: false,
            hasGhosttyCommand: false,
            isRestoreSurface: false,
            isManualSurface: false
        )
        #expect(result == nil)
    }

    @Test func nonLoginModeQuotesShellPathsWithoutReintroducingLoginFlag() {
        let result = policy.commandOverride(
            shell: "/opt/Developer Tools/z'sh",
            configuration: .init(mode: .nonLogin),
            hasExplicitCommand: false,
            hasExplicitInput: false,
            hasGhosttyCommand: false,
            isRestoreSurface: false,
            isManualSurface: false
        )
        #expect(result == "/usr/bin/env '/opt/Developer Tools/z'\\''sh' -i")
    }

    @Test func managedFishIntegrationUsesNonLoginInvocation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shell-integration-\(UUID().uuidString)")
        let fishDirectory = directory.appendingPathComponent("fish", isDirectory: true)
        try FileManager.default.createDirectory(at: fishDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("# test integration\n".utf8)
            .write(to: fishDirectory.appendingPathComponent("config.fish"))

        var environment: [String: String] = [:]
        var protectedKeys: Set<String> = []
        let command = TerminalSurface.applyManagedShellSpecificStartupEnvironment(
            shell: "/opt/fish",
            integrationDir: directory.path,
            userGhosttyShellIntegrationMode: "none",
            shellStartupMode: .nonLogin,
            to: &environment,
            protectedKeys: &protectedKeys,
            readFile: { _ in "" }
        )

        #expect(command?.hasPrefix("/usr/bin/env '/opt/fish' -i") == true)
        #expect(command?.contains("--init-command") == true)
        #expect(environment["CMUX_FISH_INTEGRATION_FILE"]?.hasSuffix("fish/config.fish") == true)
        #expect(protectedKeys.contains("CMUX_FISH_INTEGRATION_FILE"))
    }

    @Test func managedIntegrationOwnsTheLaunchCommand() {
        let result = policy.commandOverride(
            shell: "/bin/zsh",
            configuration: .init(mode: .nonLogin),
            hasExplicitCommand: false,
            hasExplicitInput: false,
            hasGhosttyCommand: false,
            isRestoreSurface: false,
            isManualSurface: false,
            hasManagedShellIntegration: true
        )
        #expect(result == nil)
    }

    @Test func managedIntegrationStillReceivesDeclarativeStartupInput() {
        let configuration = TerminalShellStartupConfiguration(
            mode: .nonLogin,
            command: "echo startup"
        )
        let launchOverride = policy.commandOverride(
            shell: "/bin/zsh",
            configuration: configuration,
            hasExplicitCommand: false,
            hasExplicitInput: false,
            hasGhosttyCommand: false,
            isRestoreSurface: false,
            isManualSurface: false,
            hasManagedShellIntegration: true
        )
        let startupInput = policy.startupInput(
            configuration: configuration,
            hasExplicitCommand: false,
            hasExplicitInput: false,
            hasGhosttyCommand: false,
            isRestoreSurface: false,
            isManualSurface: false
        )

        #expect(launchOverride == nil)
        #expect(startupInput == "echo startup\n")
    }

    @Test func blankStartupCommandIsIgnored() {
        let configuration = TerminalShellStartupConfiguration(
            mode: .login,
            command: "  \n  "
        )
        #expect(configuration.command == nil)
        #expect(
            policy.startupInput(
                configuration: configuration,
                hasExplicitCommand: false,
                hasExplicitInput: false,
                hasGhosttyCommand: false,
                isRestoreSurface: false,
                isManualSurface: false
            ) == nil
        )
    }

    @Test func startupCommandBecomesOneShotInput() {
        let result = policy.startupInput(
            configuration: .init(mode: .login, command: "mise activate zsh"),
            hasExplicitCommand: false,
            hasExplicitInput: false,
            hasGhosttyCommand: false,
            isRestoreSurface: false,
            isManualSurface: false
        )
        #expect(result == "mise activate zsh\n")
    }

    @Test(arguments: [
        (true, false, false, false, false),
        (false, true, false, false, false),
        (false, false, true, false, false),
        (false, false, false, true, false),
        (false, false, false, false, true),
    ])
    func explicitOrSpecialSurfacesAreNotOverridden(
        explicitCommand: Bool,
        explicitInput: Bool,
        ghosttyCommand: Bool,
        restore: Bool,
        manual: Bool
    ) {
        let configuration = TerminalShellStartupConfiguration(mode: .nonLogin, command: "echo startup")
        #expect(
            policy.commandOverride(
                shell: "/bin/zsh",
                configuration: configuration,
                hasExplicitCommand: explicitCommand,
                hasExplicitInput: explicitInput,
                hasGhosttyCommand: ghosttyCommand,
                isRestoreSurface: restore,
                isManualSurface: manual
            ) == nil
        )
        #expect(
            policy.startupInput(
                configuration: configuration,
                hasExplicitCommand: explicitCommand,
                hasExplicitInput: explicitInput,
                hasGhosttyCommand: ghosttyCommand,
                isRestoreSurface: restore,
                isManualSurface: manual
            ) == nil
        )
    }
}
