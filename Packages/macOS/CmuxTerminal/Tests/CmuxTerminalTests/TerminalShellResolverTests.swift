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
        let command = TerminalLaunchCommandPolicy().resolve(
            initialCommand: nil,
            surfaceCommand: nil,
            hasUserGhosttyCommand: false,
            managedShellCommand: nil,
            resolvedShell: "/run/current-system/sw/bin/fish"
        )

        #expect(command == "/run/current-system/sw/bin/fish")
    }

    @Test
    func resolvedZshLaunchesDirectlyAsALoginShell() {
        let policy = TerminalLaunchCommandPolicy()

        let appCommand = policy.ghosttyAppCommand(resolvedShell: "/bin/zsh")
        let surfaceCommand = policy.resolve(
            initialCommand: nil,
            surfaceCommand: nil,
            hasUserGhosttyCommand: false,
            managedShellCommand: nil,
            resolvedShell: "/bin/zsh"
        )

        #expect(appCommand == "direct:/bin/zsh -l")
        #expect(surfaceCommand == nil)
    }

    @Test
    func explicitGhosttyCommandWinsForResolvedZsh() {
        let command = TerminalLaunchCommandPolicy().resolve(
            initialCommand: nil,
            surfaceCommand: nil,
            hasUserGhosttyCommand: true,
            managedShellCommand: "/bin/zsh --init-command source",
            resolvedShell: "/bin/zsh"
        )

        #expect(command == nil)
    }

    @Test
    func managedZshCommandWinsOverDirectFallback() {
        let managedCommand = "/bin/zsh --init-command source"
        let command = TerminalLaunchCommandPolicy().resolve(
            initialCommand: nil,
            surfaceCommand: nil,
            hasUserGhosttyCommand: false,
            managedShellCommand: managedCommand,
            resolvedShell: "/bin/zsh"
        )

        #expect(command == managedCommand)
    }

    @Test
    func zshPathWithWhitespaceKeepsTheSurfaceFallback() {
        let policy = TerminalLaunchCommandPolicy()
        let shell = "/Applications/Custom Shell/zsh"

        let appCommand = policy.ghosttyAppCommand(resolvedShell: shell)
        let surfaceCommand = policy.resolve(
            initialCommand: nil,
            surfaceCommand: nil,
            hasUserGhosttyCommand: false,
            managedShellCommand: nil,
            resolvedShell: shell
        )

        #expect(appCommand == nil)
        #expect(surfaceCommand == shell)
    }

    @Test
    func explicitGhosttyCommandIsInheritedWithoutSurfaceOverride() {
        let command = TerminalLaunchCommandPolicy().resolve(
            initialCommand: nil,
            surfaceCommand: nil,
            hasUserGhosttyCommand: true,
            managedShellCommand: "/run/current-system/sw/bin/fish --init-command source",
            resolvedShell: "/run/current-system/sw/bin/fish"
        )

        #expect(command == nil)
    }

    @Test
    func managedFishCommandWinsOverPlainResolvedShell() {
        let command = TerminalLaunchCommandPolicy().resolve(
            initialCommand: nil,
            surfaceCommand: nil,
            hasUserGhosttyCommand: false,
            managedShellCommand: "/run/current-system/sw/bin/fish --init-command source",
            resolvedShell: "/run/current-system/sw/bin/fish"
        )

        #expect(command == "/run/current-system/sw/bin/fish --init-command source")
    }
}
