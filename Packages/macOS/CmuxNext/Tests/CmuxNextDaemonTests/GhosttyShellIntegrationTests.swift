import Foundation
import Testing
@testable import CmuxNextDaemon

/// Mirrors Ghostty's own tests in `ghostty/src/termio/shell_integration.zig`
/// and `Exec.zig`, for the environment-only injection cmux-next can do.
@Suite struct GhosttyShellIntegrationTests {
    let resources = "/App/Contents/Resources/ghostty"
    let binary = "/App/Contents/Resources/bin/ghostty"
    func dirs(_ path: String) -> Bool { path.hasPrefix("/App/Contents/Resources/ghostty/shell-integration") }

    @Test func featuresVariableMatchesGhostty() {
        func value(_ features: GhosttyShellIntegration.Features, blink: Bool? = nil) -> String? {
            GhosttyShellIntegration(features: features, cursorBlink: blink, resourcesDirectory: nil, ghosttyBinary: binary).featuresValue
        }
        let all: GhosttyShellIntegration.Features = [.cursor, .sudo, .title, .sshEnv, .sshTerminfo, .path]
        #expect(value(all) == "cursor:blink,path,ssh-env,ssh-terminfo,sudo,title")
        #expect(value([]) == nil)
        #expect(value([.sshEnv, .sudo]) == "ssh-env,sudo")
        #expect(value([.cursor], blink: false) == "cursor:steady")
        #expect(value(.ghosttyDefault) == "cursor:blink,path,title")
        // The C API's packed-struct bits: cursor, sudo, title, ssh-env, ssh-terminfo, path.
        #expect(GhosttyShellIntegration.Features(rawValue: 0b101101) == [.cursor, .title, .sshEnv, .path])
    }

    /// The ssh wrappers of Ghostty's scripts run `$GHOSTTY_BIN_DIR/ghostty
    /// +ssh`. Without a Ghostty CLI the features would make `ssh` run a
    /// missing program, so they are dropped and plain `ssh` runs.
    @Test func sshFeaturesNeedAGhosttyCLI() {
        let all: GhosttyShellIntegration.Features = [.cursor, .sudo, .title, .sshEnv, .sshTerminfo, .path]
        for missing in [nil, ""] as [String?] {
            let integration = GhosttyShellIntegration(features: all, resourcesDirectory: resources, ghosttyBinary: missing)
            #expect(integration.featuresValue == "cursor:blink,path,sudo,title")
            let env = integration.apply(to: ["SHELL": "/bin/zsh"], isDirectory: dirs)
            #expect(env["GHOSTTY_SHELL_FEATURES"] == "cursor:blink,path,sudo,title")
            #expect(env["GHOSTTY_BIN"] == nil && env["GHOSTTY_BIN_DIR"] == nil)
            let onlySSH = GhosttyShellIntegration(features: [.sshEnv, .sshTerminfo], resourcesDirectory: resources, ghosttyBinary: missing)
            #expect(onlySSH.featuresValue == nil)
        }
        let env = GhosttyShellIntegration(features: [.sshEnv], resourcesDirectory: resources, ghosttyBinary: binary)
            .apply(to: ["SHELL": "/bin/zsh"], isDirectory: dirs)
        #expect(env["GHOSTTY_SHELL_FEATURES"] == "ssh-env")
        #expect(env["GHOSTTY_BIN_DIR"] == "/App/Contents/Resources/bin")
    }

    @Test func detectsShellsLikeGhostty() {
        let detect = GhosttyShellIntegration(resourcesDirectory: resources, ghosttyBinary: nil)
        #expect(detect.shell(for: "sh") == nil)
        #expect(detect.shell(for: "/bin/zsh") == .zsh)
        #expect(detect.shell(for: "/opt/homebrew/bin/fish") == .fish)
        #expect(detect.shell(for: "elvish") == .elvish)
        #expect(detect.shell(for: "nu") == .nushell)
        #expect(detect.shell(for: "/opt/homebrew/bin/bash") == .bash)
        #expect(detect.shell(for: "/bin/bash") == nil, "Apple's bash has no ENV startup path")
        #expect(GhosttyShellIntegration(mode: .none, resourcesDirectory: resources, ghosttyBinary: nil).shell(for: "/bin/zsh") == nil)
        #expect(GhosttyShellIntegration(mode: .fish, resourcesDirectory: resources, ghosttyBinary: nil).shell(for: "/bin/zsh") == .fish)
    }

    @Test func zshInjectsZDOTDIRAndKeepsTheUsersValue() {
        let integration = GhosttyShellIntegration(resourcesDirectory: resources, ghosttyBinary: binary)
        let env = integration.apply(to: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin", "ZDOTDIR": "/Users/u/.zsh"], isDirectory: dirs)
        #expect(env["ZDOTDIR"] == "\(resources)/shell-integration/zsh")
        #expect(env["GHOSTTY_ZSH_ZDOTDIR"] == "/Users/u/.zsh")
        #expect(env["GHOSTTY_SHELL_FEATURES"] == "cursor:blink,path,title")
        #expect(env["GHOSTTY_BIN"] == binary)
        #expect(env["GHOSTTY_BIN_DIR"] == "/App/Contents/Resources/bin")
        #expect(env["PATH"] == "/usr/bin:/bin:/App/Contents/Resources/bin")
        #expect(env["XDG_DATA_DIRS"] == "/usr/local/share:/usr/share:\(resources)/..")
        #expect(env["MANPATH"] == ":\(resources)/../man")

        let fresh = integration.apply(to: ["SHELL": "/bin/zsh"], isDirectory: dirs)
        #expect(fresh["GHOSTTY_ZSH_ZDOTDIR"] == nil)
        #expect(fresh["PATH"] == "/App/Contents/Resources/bin")
        // PATH already holding the bin dir is left alone.
        let again = integration.apply(to: ["PATH": "/App/Contents/Resources/bin:/usr/bin"], isDirectory: dirs)
        #expect(again["PATH"] == "/App/Contents/Resources/bin:/usr/bin")
    }

    @Test func fishElvishAndNushellUseXDGDataDirs() {
        let integration = GhosttyShellIntegration(resourcesDirectory: resources, ghosttyBinary: nil)
        for shell in ["/opt/homebrew/bin/fish", "elvish", "nu"] {
            let env = integration.apply(to: ["SHELL": shell, "XDG_DATA_DIRS": "/opt/share", "MANPATH": "/m"], isDirectory: dirs)
            #expect(env["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] == "\(resources)/shell-integration", "\(shell)")
            #expect(env["XDG_DATA_DIRS"] == "\(resources)/shell-integration:/opt/share:\(resources)/..", "\(shell)")
            #expect(env["MANPATH"] == "/m:\(resources)/../man")
            #expect(env["ZDOTDIR"] == nil)
        }
    }

    @Test func noneAndUnknownShellsGetOnlyTheFeatureVariables() {
        let off = GhosttyShellIntegration(mode: .none, features: [.sshTerminfo], resourcesDirectory: resources, ghosttyBinary: binary)
        let env = off.apply(to: ["SHELL": "/bin/zsh"], isDirectory: dirs)
        #expect(env["ZDOTDIR"] == nil)
        #expect(env["GHOSTTY_SHELL_FEATURES"] == "ssh-terminfo", "features are set even without integration, as in Ghostty")
        #expect(env["GHOSTTY_BIN"] == binary)

        let bash = GhosttyShellIntegration(resourcesDirectory: resources, ghosttyBinary: nil)
            .apply(to: ["SHELL": "/bin/bash"], isDirectory: dirs)
        #expect(bash["ZDOTDIR"] == nil && bash["ENV"] == nil && bash["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] == nil)

        // Missing resources: no injection, no data-dir additions.
        let bare = GhosttyShellIntegration(resourcesDirectory: nil, ghosttyBinary: nil).apply(to: ["SHELL": "/bin/zsh"])
        #expect(bare == ["SHELL": "/bin/zsh", "GHOSTTY_SHELL_FEATURES": "cursor:blink,path,title"])
    }

    /// `setupBash`: POSIX mode reads the integration script from `ENV`; the
    /// user's `ENV` and history file are kept for the script to restore.
    @Test func bashWritesGhosttysPosixEnvironmentAndArguments() {
        let integration = GhosttyShellIntegration(resourcesDirectory: resources, ghosttyBinary: nil)
        let env = integration.apply(
            to: ["SHELL": "/opt/homebrew/bin/bash", "ENV": "/Users/u/.shrc", "HOME": "/Users/u"], isDirectory: dirs)
        #expect(env["ENV"] == "\(resources)/shell-integration/bash/ghostty.bash")
        #expect(env["GHOSTTY_BASH_ENV"] == "/Users/u/.shrc")
        #expect(env["GHOSTTY_BASH_INJECT"] == "1")
        #expect(env["HISTFILE"] == "/Users/u/.bash_history")
        #expect(env["GHOSTTY_BASH_UNEXPORT_HISTFILE"] == "1")
        #expect(GhosttyShellIntegration.shellArguments(for: env) == ["--posix"])

        let ownHistory = integration.apply(
            to: ["SHELL": "/opt/homebrew/bin/bash", "HISTFILE": "/tmp/h", "HOME": "/Users/u"], isDirectory: dirs)
        #expect(ownHistory["HISTFILE"] == "/tmp/h")
        #expect(ownHistory["GHOSTTY_BASH_UNEXPORT_HISTFILE"] == nil)
        #expect(ownHistory["GHOSTTY_BASH_ENV"] == nil)

        // Apple's bash, a missing script and `shell-integration = none` get no arguments.
        let apple = integration.apply(to: ["SHELL": "/bin/bash"], isDirectory: dirs)
        #expect(apple["GHOSTTY_BASH_INJECT"] == nil)
        #expect(GhosttyShellIntegration.shellArguments(for: apple) == nil)
        let missing = integration.apply(to: ["SHELL": "/opt/homebrew/bin/bash"], isDirectory: { _ in false })
        #expect(GhosttyShellIntegration.shellArguments(for: missing) == nil)
        let off = GhosttyShellIntegration(mode: .none, resourcesDirectory: resources, ghosttyBinary: nil)
            .apply(to: ["SHELL": "/opt/homebrew/bin/bash"], isDirectory: dirs)
        #expect(GhosttyShellIntegration.shellArguments(for: off) == nil)
    }

    /// `setupNushell`: the module comes from `XDG_DATA_DIRS`, the `use` from
    /// `--execute`.
    @Test func nushellGetsTheUseArgument() {
        let integration = GhosttyShellIntegration(resourcesDirectory: resources, ghosttyBinary: nil)
        let env = integration.apply(to: ["SHELL": "/opt/homebrew/bin/nu"], isDirectory: dirs)
        #expect(GhosttyShellIntegration.shellArguments(for: env) == ["--execute", "use ghostty *"])
        // zsh, fish and elvish are integrated through the environment alone.
        for shell in ["/bin/zsh", "/opt/homebrew/bin/fish", "elvish"] {
            let other = integration.apply(to: ["SHELL": shell], isDirectory: dirs)
            #expect(GhosttyShellIntegration.shellArguments(for: other) == nil, "\(shell)")
        }
        // A forced mode never gives another shell bash or nushell arguments.
        let forced = GhosttyShellIntegration(mode: .bash, resourcesDirectory: resources, ghosttyBinary: nil)
            .apply(to: ["SHELL": "/bin/zsh", "HOME": "/Users/u"], isDirectory: dirs)
        #expect(GhosttyShellIntegration.shellArguments(for: forced) == nil)
    }

    /// The terminal env provider applies the integration on top of the
    /// login environment, so it sees the login PATH and SHELL.
    @Test func sharedProviderAppliesTheIntegration() async {
        let provider = TerminalEnvironment.instance.shared(
            base: ["PATH": "/usr/bin", "SHELL": "/bin/zsh"],
            overrides: ["TERM": "xterm-ghostty"],
            login: { ["PATH": "/opt/homebrew/bin:/usr/bin", "SHELL": "/bin/zsh"] },
            integration: { GhosttyShellIntegration(resourcesDirectory: "/App/Contents/Resources/ghostty", ghosttyBinary: "/App/Contents/Resources/bin/ghostty") }
        )
        let env = await provider()
        #expect(env["TERM"] == "xterm-ghostty")
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/bin:/App/Contents/Resources/bin")
        #expect(env["GHOSTTY_SHELL_FEATURES"] == "cursor:blink,path,title")
    }
}
