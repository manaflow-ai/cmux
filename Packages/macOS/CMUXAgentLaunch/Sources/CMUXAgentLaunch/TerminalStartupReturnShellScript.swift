import Foundation

/// Generates the zsh lines that run a resume/fork command in the user's login shell and then
/// return control to a fresh interactive login shell, so killing the resumed agent leaves the
/// surface in a normal shell rather than exiting.
///
/// The command runs through `$SHELL` (defaulting to `/bin/zsh`): for `zsh`/`bash` it uses an
/// interactive login shell (`-lic`), for the C shells and any other shell a non-interactive
/// `-c`. After the command, the script restores cmux's `ZDOTDIR` shell-integration reentry for
/// `zsh`, optionally returns the outer login shell to the session's working directory (the
/// resume command's own `cd` runs inside the child shell above, so without this the outer shell
/// would land in the launcher's cwd), and finally `exec -l`s a fresh login `$SHELL`.
///
/// The type is a stateless value; construct one at the call site
/// (`TerminalStartupReturnShellScript()`) rather than reaching through a static namespace, per the
/// package design discipline.
public struct TerminalStartupReturnShellScript: Sendable, Equatable {
    private static let shellLine = #"_cmux_resume_shell="${SHELL:-/bin/zsh}""#
    private static let zshIntegrationReentryLines = [
        #"if [[ "${_cmux_resume_shell:t}" == "zsh" && -n "${CMUX_SHELL_INTEGRATION_DIR:-}" && -r "${CMUX_SHELL_INTEGRATION_DIR}/.zshenv" ]]; then"#,
        #"  if [[ -n "${ZDOTDIR+X}" ]]; then"#,
        #"    export CMUX_ZSH_ZDOTDIR="$ZDOTDIR""#,
        #"  else"#,
        #"    unset CMUX_ZSH_ZDOTDIR"#,
        #"  fi"#,
        #"  export ZDOTDIR="$CMUX_SHELL_INTEGRATION_DIR""#,
        #"fi"#,
    ]

    /// Creates a return-to-login-shell script generator. The type holds no state.
    public init() {}

    /// Builds the zsh lines that run `command` through `$SHELL` and then `exec -l` a fresh login
    /// shell.
    ///
    /// When `workingDirectory` is present (non-empty once trimmed), an outer `cd` to it is emitted
    /// before the final `exec -l` so that exiting the resumed agent returns the surface to the
    /// session's directory.
    public func commandThenReturnLines(command: String, workingDirectory: String? = nil) -> [String] {
        let quotedCommand = TerminalStartupShellQuoting().singleQuoted(command)
        var lines = [
            Self.shellLine,
            #"case "${_cmux_resume_shell:t}" in"#,
            #"  zsh|bash) "$_cmux_resume_shell" -lic \#(quotedCommand) ;;"#,
            #"  csh|tcsh) "$_cmux_resume_shell" -c \#(quotedCommand) ;;"#,
            #"  *) "$_cmux_resume_shell" -c \#(quotedCommand) ;;"#,
            #"esac"#,
        ] + Self.zshIntegrationReentryLines
        // The resume command's `cd` runs inside the child shell above, so after the resumed agent
        // exits the outer login shell would otherwise land in this script's launch cwd (the surface
        // default), not the session's directory. Return the outer shell to the session's working
        // directory so killing a resumed agent leaves you where the session lived.
        if let workingDirectory, !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let quotedDirectory = TerminalStartupShellQuoting().singleQuoted(workingDirectory)
            lines.append(#"{ cd -- \#(quotedDirectory) 2>/dev/null || true; }"#)
        }
        lines.append(#"exec -l "$_cmux_resume_shell""#)
        return lines
    }
}
