import Testing
@testable import CmuxTerminal

@Suite
struct TerminalShellResolverTests {
    @Test
    func validLoginShellWinsOverStaleEnvironmentShell() {
        let nixFish = "/run/current-system/sw/bin/fish"
        let staleHomebrewFish = "/opt/homebrew/bin/fish"
        let resolver = TerminalShellResolver(isExecutable: { $0 == nixFish })

        let resolved = resolver.resolve(
            loginShell: nixFish,
            environmentShell: staleHomebrewFish,
            declaredShells: [nixFish]
        )

        #expect(resolved == nixFish)
    }

    @Test
    func declaredRelocationPreservesPreferredShellFamily() {
        let staleNixFish = "/run/old-system/sw/bin/fish"
        let staleHomebrewFish = "/opt/homebrew/bin/fish"
        let currentNixFish = "/nix/store/current-system/bin/fish"
        let resolver = TerminalShellResolver(isExecutable: { $0 == currentNixFish })

        let resolved = resolver.resolve(
            loginShell: staleNixFish,
            environmentShell: staleHomebrewFish,
            declaredShells: ["/bin/bash", currentNixFish]
        )

        #expect(resolved == currentNixFish)
    }

    @Test
    func invalidCandidatesFallBackToExecutableZsh() {
        let resolver = TerminalShellResolver(isExecutable: { $0 == "/bin/zsh" })

        let resolved = resolver.resolve(
            loginShell: "/missing/fish",
            environmentShell: "/also/missing/fish",
            declaredShells: ["/missing/fish"]
        )

        #expect(resolved == "/bin/zsh")
    }

    @Test
    func resolverNeverReturnsANonExecutableCandidate() {
        let resolver = TerminalShellResolver(isExecutable: { _ in false })

        let resolved = resolver.resolve(
            loginShell: "/missing/fish",
            environmentShell: "/missing/zsh",
            declaredShells: ["/missing/bash"]
        )

        #expect(resolved == nil)
    }

    @Test
    func resolvedShellBecomesTheDefaultSurfaceCommand() {
        let launchForm = TerminalLaunchCommandPolicy().resolve(
            initialCommand: nil,
            surfaceCommand: nil,
            userGhosttyCommand: nil,
            managedShellCommand: nil,
            resolvedShell: "/run/current-system/sw/bin/fish"
        )

        #expect(launchForm?.command == "/run/current-system/sw/bin/fish")
        #expect(launchForm?.arguments == nil)
    }

    @Test
    func explicitGhosttyShellCommandKeepsItsShellLaunchForm() {
        let launchForm = TerminalLaunchCommandPolicy().resolve(
            initialCommand: nil,
            surfaceCommand: nil,
            userGhosttyCommand: GhosttyConfiguredCommand(
                rawValue: "shell: exec /usr/local/bin/nu --login"
            ),
            managedShellCommand: "/run/current-system/sw/bin/fish --init-command source",
            resolvedShell: "/run/current-system/sw/bin/fish"
        )

        #expect(launchForm?.command == "exec /usr/local/bin/nu --login")
        #expect(launchForm?.arguments == nil)
    }

    @Test
    func explicitGhosttyDirectCommandKeepsItsArgumentLaunchForm() {
        let launchForm = TerminalLaunchCommandPolicy().resolve(
            initialCommand: nil,
            surfaceCommand: nil,
            userGhosttyCommand: GhosttyConfiguredCommand(
                rawValue: " direct: /usr/local/bin/nu --login "
            ),
            managedShellCommand: nil,
            resolvedShell: "/bin/zsh"
        )

        #expect(launchForm?.command == nil)
        #expect(launchForm?.arguments == ["/usr/local/bin/nu", "--login"])
    }

    @Test
    func inheritedSurfaceDirectCommandKeepsItsArgumentLaunchForm() {
        let launchForm = TerminalLaunchCommandPolicy().resolve(
            initialCommand: nil,
            surfaceCommand: "direct:/usr/local/bin/nu --login",
            userGhosttyCommand: nil,
            managedShellCommand: nil,
            resolvedShell: "/bin/zsh"
        )

        #expect(launchForm?.command == nil)
        #expect(launchForm?.arguments == ["/usr/local/bin/nu", "--login"])
    }

    @Test
    func ghosttyDirectCommandTreatsQuotesAsLiteralCharacters() {
        let configuredCommand = GhosttyConfiguredCommand(
            rawValue: "direct:/bin/zsh -c 'printf hello world'"
        )

        #expect(
            configuredCommand?.launchForm.arguments == [
                "/bin/zsh", "-c", "'printf", "hello", "world'",
            ]
        )
    }

    @Test
    func ghosttyDirectCommandPreservesEmptyArgumentsBetweenSpaces() {
        let configuredCommand = GhosttyConfiguredCommand(
            rawValue: "direct:/bin/echo  tail"
        )

        #expect(configuredCommand?.launchForm.arguments == ["/bin/echo", "", "tail"])
    }

    @Test
    func emptyGhosttyDirectCommandIsRejectedBeforeLaunch() {
        #expect(GhosttyConfiguredCommand(rawValue: "direct:") == nil)
        #expect(TerminalSurfaceLaunchForm(arguments: [""]) == nil)
    }

    @Test
    func managedFishCommandWinsOverPlainResolvedShell() {
        let launchForm = TerminalLaunchCommandPolicy().resolve(
            initialCommand: nil,
            surfaceCommand: nil,
            userGhosttyCommand: nil,
            managedShellCommand: "/run/current-system/sw/bin/fish --init-command source",
            resolvedShell: "/run/current-system/sw/bin/fish"
        )

        #expect(
            launchForm?.command
                == "/run/current-system/sw/bin/fish --init-command source"
        )
        #expect(launchForm?.arguments == nil)
    }
}
