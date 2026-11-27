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
    // ZDOTDIR holds the user's value (unset when that is just $HOME) so
    // `${ZDOTDIR:-$HOME}` paths (zimfw, oh-my-zsh) and `: ${ZDOTDIR:=...}`
    // defaults behave as in a plain ssh login (#12080). A ZDOTDIR the user's
    // file sets is kept for the files after it. .zlogin is the last startup
    // file, so it leaves the user's value in place for the session.
    private var restoreUserZdotdirLine: String {
        "if [ \"${CMUX_REAL_ZDOTDIR:-$HOME}\" = \"$HOME\" ]; then unset ZDOTDIR; else export ZDOTDIR=\"$CMUX_REAL_ZDOTDIR\"; fi"
    }

    private var captureUserZdotdirLine: String {
        "if [ -n \"${ZDOTDIR:-}\" ] && [ \"$ZDOTDIR\" != \"\(shellStateDir)\" ]; then export CMUX_REAL_ZDOTDIR=\"$ZDOTDIR\"; fi"
    }

    private var relayZdotdirLine: String {
        "export ZDOTDIR=\"\(shellStateDir)\""
    }

    var zshEnvLines: [String] {
        [
            restoreUserZdotdirLine,
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zshenv\" ] && source \"$CMUX_REAL_ZDOTDIR/.zshenv\"",
            captureUserZdotdirLine,
        ] + sharedHistoryLines + [
            // Stays set even for `zsh -c`: a RemoteCommand like `exec zsh`
            // relies on it to start the next shell through the relay files.
            relayZdotdirLine,
        ]
    }

    var zshProfileLines: [String] {
        [
            restoreUserZdotdirLine,
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zprofile\" ] && source \"$CMUX_REAL_ZDOTDIR/.zprofile\"",
            captureUserZdotdirLine,
            relayZdotdirLine,
        ]
    }

    func zshRCLines(commonShellLines: [String]) -> [String] {
        sharedHistoryLines + [
            restoreUserZdotdirLine,
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zshrc\" ] && source \"$CMUX_REAL_ZDOTDIR/.zshrc\"",
            captureUserZdotdirLine,
            relayZdotdirLine,
        ] + commonShellLines + [
            // A non-login interactive shell reads no .zlogin, so restore here.
            "if [[ ! -o login ]]; then \(restoreUserZdotdirLine); fi",
        ]
    }

    var zshLoginLines: [String] {
        [
            restoreUserZdotdirLine,
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zlogin\" ] && source \"$CMUX_REAL_ZDOTDIR/.zlogin\"",
        ]
    }
}
