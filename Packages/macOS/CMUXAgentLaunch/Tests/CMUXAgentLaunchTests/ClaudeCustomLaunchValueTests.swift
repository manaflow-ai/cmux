import CMUXAgentLaunch
import Foundation
import Testing

struct ClaudeCustomLaunchValueTests {
    private let launch = ClaudeCustomLaunchValue()

    @Test
    func executableFileKeepsBinaryModeEvenWithSpaces() {
        let path = "/Users/someone/dir with space/claude"
        let classification = launch.classify(
            configuredValue: path,
            isExecutableFile: { $0 == path }
        )
        #expect(classification == .executablePath(path))
    }

    @Test
    func commandReferencingArgumentsClassifiesAsShellCommand() {
        let command = #"/bin/zsh -lic 'claude "$@"' claude "$@""#
        let classification = launch.classify(
            configuredValue: command,
            isExecutableFile: { _ in false }
        )
        #expect(classification == .shellCommand(command))
    }

    // Command mode requires the literal $@ marker: a stale path containing
    // spaces must keep the historical silent PATH fallback rather than
    // hard-failing through /bin/sh.
    @Test
    func staleSpacedPathWithoutArgumentsReferenceFallsBack() {
        let classification = launch.classify(
            configuredValue: "/Users/someone/dir with space/claude",
            isExecutableFile: { _ in false }
        )
        #expect(classification == .pathFallback)
    }

    // An unexpanded shell-variable path must not become a command that would
    // run the binary while silently dropping every argument.
    @Test
    func unexpandedHomeVariablePathFallsBack() {
        let classification = launch.classify(
            configuredValue: "$HOME/bin/claude",
            isExecutableFile: { _ in false }
        )
        #expect(classification == .pathFallback)
    }

    @Test
    func commandWithoutArgumentsReferenceFallsBack() {
        let classification = launch.classify(
            configuredValue: "zsh -lic claude",
            isExecutableFile: { _ in false }
        )
        #expect(classification == .pathFallback)
    }

    @Test
    func trimsSurroundingWhitespaceBeforeClassifying() {
        let classification = launch.classify(
            configuredValue: "  my-wrapper \"$@\"\n",
            isExecutableFile: { _ in false }
        )
        #expect(classification == .shellCommand("my-wrapper \"$@\""))
    }

    @Test
    func stalePlainPathFallsBackToPathResolution() {
        let classification = launch.classify(
            configuredValue: "/opt/deleted/claude",
            isExecutableFile: { _ in false }
        )
        #expect(classification == .pathFallback)
    }

    @Test
    func emptyAndNilValuesFallBack() {
        #expect(launch.classify(configuredValue: nil, isExecutableFile: { _ in true }) == .pathFallback)
        #expect(launch.classify(configuredValue: "   ", isExecutableFile: { _ in true }) == .pathFallback)
    }

    @Test
    func shellCommandArgvAppendsAgentArgumentsAfterArgvZero() {
        let argv = launch.shellCommandArgv(
            command: #"my-wrapper "$@""#,
            arguments: ["--resume", "abc"]
        )
        #expect(argv == ["/bin/sh", "-c", #"my-wrapper "$@""#, "claude", "--resume", "abc"])
    }

    @Test
    func guardEnvironmentKeyIsStable() {
        // The bash mirror in Resources/bin/cmux-claude-wrapper hardcodes this name.
        #expect(ClaudeCustomLaunchValue.commandActiveGuardEnvironmentKey == "CMUX_CLAUDE_CUSTOM_COMMAND_ACTIVE")
    }
}
