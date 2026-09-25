import Foundation

enum RemoteShellEnvironment {
    static func utf8LocaleSetupLines() -> [String] {
        [
            "case \"${LC_ALL:-${LC_CTYPE:-${LANG:-}}}\" in",
            "  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;",
            "  *) export LANG='C.UTF-8'; export LC_CTYPE='C.UTF-8'; export LC_ALL='C.UTF-8' ;;",
            "esac",
        ]
    }
}

struct RemoteRelayZshBootstrap {
    let shellStateDir: String

    private var sharedHistoryLines: [String] {
        [
            "if [ -z \"${HISTFILE:-}\" ] || [ \"$HISTFILE\" = \"\(shellStateDir)/.zsh_history\" ]; then export HISTFILE=\"$CMUX_REAL_ZDOTDIR/.zsh_history\"; fi",
        ]
    }

    // zsh finds each startup file through the current ZDOTDIR, so the relay
    // dir has to stay in ZDOTDIR between files. While a user file runs,
    // ZDOTDIR points at the real directory so `${ZDOTDIR:-$HOME}` paths
    // (zimfw, oh-my-zsh) resolve there (#12080). .zlogin is the last startup
    // file, so it leaves the real value in place for the session.
    private var restoreUserZdotdirLine: String {
        "export ZDOTDIR=\"${CMUX_REAL_ZDOTDIR:-$HOME}\""
    }

    private var relayZdotdirLine: String {
        "export ZDOTDIR=\"\(shellStateDir)\""
    }

    var zshEnvLines: [String] {
        [
            restoreUserZdotdirLine,
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zshenv\" ] && source \"$CMUX_REAL_ZDOTDIR/.zshenv\"",
            "if [ -n \"${ZDOTDIR:-}\" ] && [ \"$ZDOTDIR\" != \"\(shellStateDir)\" ]; then export CMUX_REAL_ZDOTDIR=\"$ZDOTDIR\"; fi",
        ] + sharedHistoryLines + [
            relayZdotdirLine,
        ]
    }

    var zshProfileLines: [String] {
        [
            restoreUserZdotdirLine,
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zprofile\" ] && source \"$CMUX_REAL_ZDOTDIR/.zprofile\"",
            relayZdotdirLine,
        ]
    }

    func zshRCLines(commonShellLines: [String]) -> [String] {
        sharedHistoryLines + [
            restoreUserZdotdirLine,
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zshrc\" ] && source \"$CMUX_REAL_ZDOTDIR/.zshrc\"",
            relayZdotdirLine,
        ] + commonShellLines
    }

    var zshLoginLines: [String] {
        [
            restoreUserZdotdirLine,
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zlogin\" ] && source \"$CMUX_REAL_ZDOTDIR/.zlogin\"",
        ]
    }
}
