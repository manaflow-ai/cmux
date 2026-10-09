import Testing
@testable import CmuxNextDaemon

/// A cmux-next terminal must run this app's bundled `cmux`, even when the
/// login PATH (or a startup file) lists an older `cmux` first
/// (`~/.local/bin/cmux`, the classic app's CLI). The spawn env puts the
/// bundled bin dir first and wraps the shell so it stays first after the
/// startup files (`scripts/cmux-next/tests/cli-path-integration.test.sh`
/// runs the real shells).
@Suite struct BundledCLIEnvironmentTests {
    let bin = "/App/Contents/Resources/bin"
    let layer = "/App/Contents/Resources/cmux-cli-path"
    var cli: BundledCLIEnvironment { BundledCLIEnvironment(binDirectory: bin, pathIntegration: layer) }
    func executable(_ path: String) -> Bool { path == "/App/Contents/Resources/bin/cmux" }
    func exists(_ path: String) -> Bool { path.hasPrefix(layer) }

    @Test func bundledCLIGoesFirstOnPathWithoutAGhosttyCLI() {
        let env = cli.apply(to: ["PATH": "/Users/u/.local/bin:\(bin):/usr/bin", "SHELL": "/bin/sh"],
                            isExecutable: executable, fileExists: exists)
        #expect(env["PATH"] == "\(bin):/Users/u/.local/bin:/usr/bin")
        #expect(env["CMUX_BUNDLED_CLI_PATH"] == "\(bin)/cmux")
    }

    @Test func zshGetsTheLayerOverTheIntegrationZDOTDIR() {
        let ghostty = "/App/Contents/Resources/ghostty/shell-integration/zsh"
        let env = cli.apply(to: ["PATH": "/usr/bin", "SHELL": "/bin/zsh", "ZDOTDIR": ghostty],
                            isExecutable: executable, fileExists: exists)
        #expect(env["ZDOTDIR"] == "\(layer)/zsh")
        #expect(env[BundledCLIEnvironment.zshNextZDOTDIRKey] == ghostty)
    }

    @Test func zshWithoutZDOTDIRChainsToHome() {
        let env = cli.apply(to: ["PATH": "/usr/bin", "SHELL": "/bin/zsh"], isExecutable: executable, fileExists: exists)
        #expect(env["ZDOTDIR"] == "\(layer)/zsh")
        #expect(env[BundledCLIEnvironment.zshNextZDOTDIRKey] == nil)
    }

    @Test func bashWrapsGhosttysPosixEnvScriptAndKeepsPosixArgs() {
        let ghostty = "/App/Contents/Resources/ghostty/shell-integration/bash/ghostty.bash"
        let env = cli.apply(
            to: ["PATH": "/usr/bin", "SHELL": "/opt/homebrew/bin/bash", "ENV": ghostty, "GHOSTTY_BASH_INJECT": "1"],
            isExecutable: executable, fileExists: exists)
        #expect(env["ENV"] == "\(layer)/bash/cmux-cli-path.bash")
        #expect(env[BundledCLIEnvironment.bashNextEnvKey] == ghostty)
        #expect(GhosttyShellIntegration.shellArguments(for: env) == ["--posix"])
    }

    @Test func bashWithoutGhosttyIntegrationIsLeftAlone() {
        let env = cli.apply(to: ["PATH": "/usr/bin", "SHELL": "/bin/bash"], isExecutable: executable, fileExists: exists)
        #expect(env["ENV"] == nil)
        #expect(env["PATH"] == "\(bin):/usr/bin")
    }

    @Test func fishGetsAVendorConfDataDir() {
        let env = cli.apply(to: ["PATH": "/usr/bin", "SHELL": "/opt/homebrew/bin/fish", "XDG_DATA_DIRS": "/x"],
                            isExecutable: executable, fileExists: exists)
        #expect(env["XDG_DATA_DIRS"] == "\(layer):/x")
        #expect(env[BundledCLIEnvironment.fishDataDirKey] == layer)
    }

    @Test func noBundledCLILeavesTheEnvUnchanged() {
        let input = ["PATH": "/usr/bin", "SHELL": "/bin/zsh"]
        #expect(cli.apply(to: input, isExecutable: { _ in false }, fileExists: exists) == input)
    }

    @Test func withoutTheLayerOnlyThePathChanges() {
        let plain = BundledCLIEnvironment(binDirectory: bin, pathIntegration: nil)
        let env = plain.apply(to: ["PATH": "/usr/bin", "SHELL": "/bin/zsh"], isExecutable: executable, fileExists: exists)
        #expect(env == ["PATH": "\(bin):/usr/bin", "SHELL": "/bin/zsh", "CMUX_BUNDLED_CLI_PATH": "\(bin)/cmux"])
    }
}
