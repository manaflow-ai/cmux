import Foundation

/// Builds zsh launcher-script lines for an agent resume command.
///
/// The builder owns the shell shape shared by local app restores and CLI-created resume surfaces:
/// run the supplied command in a child shell, optionally retry a known transient failure, then exec
/// a fresh login shell from the saved working directory so a failed or exited agent leaves the
/// visible terminal where the session lived.
public struct AgentResumeShellScriptBuilder: Sendable, Equatable {
    private let quoting = AgentResumeShellQuoting()

    /// Creates a shell-script builder. The type holds no runtime state.
    public init() {}

    /// Builds the launcher lines that run `command` and then return to a login shell.
    ///
    /// The command is executed exactly as supplied. If the command must start from a directory, the
    /// caller should include that `cd` in the command text. The `workingDirectory` value controls the
    /// directory restored before the final login shell is `exec`ed.
    ///
    /// - Parameters:
    ///   - command: The shell command to run in the child shell.
    ///   - workingDirectory: The directory for the final visible shell after the command exits.
    ///   - retryPolicy: A bounded retry policy for transient launch failures.
    /// - Returns: zsh script lines to append after a shebang.
    public func commandThenReturnLines(
        command: String,
        workingDirectory: String? = nil,
        retryPolicy: AgentResumeRetryPolicy = .disabled
    ) -> [String] {
        var lines = [
            #"_cmux_resume_shell="${SHELL:-/bin/zsh}""#,
        ]
        if retryPolicy.isEnabled {
            lines.append(contentsOf: retryingCommandLines(command: command, retryPolicy: retryPolicy))
        } else {
            lines.append(contentsOf: plainCommandLines(command: command))
        }
        lines.append(contentsOf: zshIntegrationReentryLines)
        if let workingDirectory,
           !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(#"{ cd -- \#(quoting.singleQuoted(workingDirectory)) 2>/dev/null || true; }"#)
        }
        lines.append(#"exec -l "$_cmux_resume_shell""#)
        return lines
    }

    private var zshIntegrationReentryLines: [String] {
        [
            #"if [[ "${_cmux_resume_shell:t}" == "zsh" && -n "${CMUX_SHELL_INTEGRATION_DIR:-}" && -r "${CMUX_SHELL_INTEGRATION_DIR}/.zshenv" ]]; then"#,
            #"  if [[ -n "${ZDOTDIR+X}" ]]; then"#,
            #"    export CMUX_ZSH_ZDOTDIR="$ZDOTDIR""#,
            #"  else"#,
            #"    unset CMUX_ZSH_ZDOTDIR"#,
            #"  fi"#,
            #"  export ZDOTDIR="$CMUX_SHELL_INTEGRATION_DIR""#,
            #"fi"#,
        ]
    }

    private func plainCommandLines(command: String) -> [String] {
        let quotedCommand = quoting.singleQuoted(command)
        return [
            #"case "${_cmux_resume_shell:t}" in"#,
            #"  zsh|bash) "$_cmux_resume_shell" -lic \#(quotedCommand) ;;"#,
            #"  csh|tcsh) "$_cmux_resume_shell" -c \#(quotedCommand) ;;"#,
            #"  *) "$_cmux_resume_shell" -c \#(quotedCommand) ;;"#,
            #"esac"#,
        ]
    }

    private func retryingCommandLines(command: String, retryPolicy: AgentResumeRetryPolicy) -> [String] {
        let quotedCommand = quoting.singleQuoted(command)
        let quotedPattern = quoting.singleQuoted(retryPolicy.shellGrepPattern)
        let retryCount = max(0, retryPolicy.maximumRetries)
        let retryDelay = String(format: "%.3f", max(0, retryPolicy.delaySeconds))
        let retryStartupSeconds = max(0, retryPolicy.startupFailureWindowSeconds)
        return [
            #"_cmux_resume_command=\#(quotedCommand)"#,
            #"_cmux_resume_retry_limit="${CMUX_AGENT_RESUME_RETRY_LIMIT:-\#(retryCount)}""#,
            #"case "$_cmux_resume_retry_limit" in"#,
            #"  ''|*[!0-9]*) _cmux_resume_retry_limit=\#(retryCount) ;;"#,
            #"esac"#,
            #"_cmux_resume_retry_delay="${CMUX_AGENT_RESUME_RETRY_DELAY_SECONDS:-\#(retryDelay)}""#,
            #"case "$_cmux_resume_retry_delay" in"#,
            #"  ''|*[!0-9.]*) _cmux_resume_retry_delay=\#(retryDelay) ;;"#,
            #"esac"#,
            #"_cmux_resume_retry_startup_seconds="${CMUX_AGENT_RESUME_RETRY_STARTUP_SECONDS:-\#(retryStartupSeconds)}""#,
            #"case "$_cmux_resume_retry_startup_seconds" in"#,
            #"  ''|*[!0-9]*) _cmux_resume_retry_startup_seconds=\#(retryStartupSeconds) ;;"#,
            #"esac"#,
            #"_cmux_resume_retry=0"#,
            #"_cmux_resume_log="""#,
            #"_cmux_resume_cleanup_log() {"#,
            #"  if [ -n "$_cmux_resume_log" ]; then"#,
            #"    rm -f -- "$_cmux_resume_log" 2>/dev/null || true"#,
            #"  fi"#,
            #"}"#,
            #"_cmux_resume_capture_log() {"#,
            #"  /bin/dd bs=4096 count=1 of="$1" 2>/dev/null"#,
            #"  /bin/cat >/dev/null"#,
            #"}"#,
            #"trap _cmux_resume_cleanup_log EXIT INT TERM"#,
            #"while true; do"#,
            #"  _cmux_resume_log="${TMPDIR:-/tmp}/cmux-agent-resume-${$}-${_cmux_resume_retry}.log""#,
            #"  rm -f -- "$_cmux_resume_log" 2>/dev/null || true"#,
            #"  : > "$_cmux_resume_log" 2>/dev/null && chmod 600 "$_cmux_resume_log" 2>/dev/null || true"#,
            #"  _cmux_resume_started_at=$(/bin/date +%s 2>/dev/null || echo 0)"#,
            #"  case "${_cmux_resume_shell:t}" in"#,
            #"    zsh|bash)"#,
            #"      if [ -x /usr/bin/script ]; then"#,
            #"        /usr/bin/script -q -F >(_cmux_resume_capture_log "$_cmux_resume_log") "$_cmux_resume_shell" -lic "$_cmux_resume_command""#,
            #"      else"#,
            #"        "$_cmux_resume_shell" -lic "$_cmux_resume_command""#,
            #"      fi"#,
            #"      ;;"#,
            #"    csh|tcsh)"#,
            #"      if [ -x /usr/bin/script ]; then"#,
            #"        /usr/bin/script -q -F >(_cmux_resume_capture_log "$_cmux_resume_log") "$_cmux_resume_shell" -c "$_cmux_resume_command""#,
            #"      else"#,
            #"        "$_cmux_resume_shell" -c "$_cmux_resume_command""#,
            #"      fi"#,
            #"      ;;"#,
            #"    *)"#,
            #"      if [ -x /usr/bin/script ]; then"#,
            #"        /usr/bin/script -q -F >(_cmux_resume_capture_log "$_cmux_resume_log") "$_cmux_resume_shell" -c "$_cmux_resume_command""#,
            #"      else"#,
            #"        "$_cmux_resume_shell" -c "$_cmux_resume_command""#,
            #"      fi"#,
            #"      ;;"#,
            #"  esac"#,
            #"  _cmux_resume_status=$?"#,
            #"  if [ "$_cmux_resume_status" -eq 0 ]; then"#,
            #"    break"#,
            #"  fi"#,
            #"  _cmux_resume_finished_at=$(/bin/date +%s 2>/dev/null || echo 0)"#,
            #"  _cmux_resume_elapsed=$((_cmux_resume_finished_at - _cmux_resume_started_at))"#,
            #"  if [ "$_cmux_resume_elapsed" -lt 0 ]; then"#,
            #"    _cmux_resume_elapsed=$_cmux_resume_retry_startup_seconds"#,
            #"  fi"#,
            #"  if [ "$_cmux_resume_elapsed" -gt "$_cmux_resume_retry_startup_seconds" ]; then"#,
            #"    break"#,
            #"  fi"#,
            #"  if ! /usr/bin/grep -Eiq \#(quotedPattern) "$_cmux_resume_log" 2>/dev/null; then"#,
            #"    break"#,
            #"  fi"#,
            #"  if [ "$_cmux_resume_retry" -ge "$_cmux_resume_retry_limit" ]; then"#,
            #"    break"#,
            #"  fi"#,
            #"  _cmux_resume_retry=$((_cmux_resume_retry + 1))"#,
            #"  if [ "$_cmux_resume_retry_delay" != "0" ]; then"#,
            #"    sleep "$_cmux_resume_retry_delay""#,
            #"    _cmux_resume_stagger=$((($$ + _cmux_resume_retry) % 7))"#,
            #"    if [ "$_cmux_resume_stagger" -gt 0 ]; then"#,
            #"      sleep "0.${_cmux_resume_stagger}""#,
            #"    fi"#,
            #"  fi"#,
            #"done"#,
            #"_cmux_resume_cleanup_log"#,
            #"trap - EXIT INT TERM"#,
        ]
    }
}
