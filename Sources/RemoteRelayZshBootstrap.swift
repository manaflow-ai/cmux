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

    var zshEnvLines: [String] {
        [
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zshenv\" ] && source \"$CMUX_REAL_ZDOTDIR/.zshenv\"",
            "if [ -n \"${ZDOTDIR:-}\" ] && [ \"$ZDOTDIR\" != \"\(shellStateDir)\" ]; then export CMUX_REAL_ZDOTDIR=\"$ZDOTDIR\"; fi",
        ] + sharedHistoryLines + [
            "export ZDOTDIR=\"\(shellStateDir)\"",
        ]
    }

    var zshProfileLines: [String] {
        [
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zprofile\" ] && source \"$CMUX_REAL_ZDOTDIR/.zprofile\"",
        ]
    }

    func zshRCLines(commonShellLines: [String]) -> [String] {
        sharedHistoryLines + [
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zshrc\" ] && source \"$CMUX_REAL_ZDOTDIR/.zshrc\"",
        ] + commonShellLines
    }

    var zshLoginLines: [String] {
        [
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zlogin\" ] && source \"$CMUX_REAL_ZDOTDIR/.zlogin\"",
        ]
    }
}
