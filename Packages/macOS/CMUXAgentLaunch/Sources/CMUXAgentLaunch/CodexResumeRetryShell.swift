import Foundation

/// Renders a shell wrapper that retries transient Codex state database locks.
///
/// Use this around already-rendered `codex resume` or `codex fork` shell commands. The wrapper keeps
/// stdin/stdout connected to the terminal and mirrors stderr while capturing it, then retries only
/// when Codex exits non-zero with the shared `state_5.sqlite` lock diagnostics.
public struct CodexResumeRetryShell: Sendable, Equatable {
    /// The default number of total launch attempts, including the first attempt.
    public static let defaultMaxAttempts = 4

    /// The number of total launch attempts, including the first attempt.
    public var maxAttempts: Int

    /// Creates a Codex retry shell renderer.
    ///
    /// - Parameter maxAttempts: Total launch attempts, including the first attempt. Values below
    ///   `1` are clamped to `1`.
    public init(maxAttempts: Int = Self.defaultMaxAttempts) {
        self.maxAttempts = max(1, maxAttempts)
    }

    /// Wraps a rendered Codex command in a retrying `/bin/zsh -lc` launcher.
    ///
    /// - Parameters:
    ///   - command: The already shell-rendered Codex command to execute.
    ///   - quote: A shell quoting function for the generated zsh script.
    /// - Returns: `command` unchanged when retries are disabled; otherwise a shell command that
    ///   retries transient Codex state database lock failures with bounded jittered backoff.
    public func wrappedCommand(_ command: String, quote: (String) -> String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxAttempts > 1, !trimmed.isEmpty else { return command }
        guard !trimmed.contains("_cmux_codex_retry_limit") else { return trimmed }
        return "/bin/zsh -lc \(quote(retryScript(command: trimmed)))"
    }

    private func retryScript(command: String) -> String {
        """
        _cmux_codex_retry_stderr=""
        _cmux_codex_retry_pipe=""
        _cmux_codex_retry_cleanup() {
          if [ -n "$_cmux_codex_retry_pipe" ]; then
            rm -f "$_cmux_codex_retry_pipe" 2>/dev/null || true
          fi
          if [ -n "$_cmux_codex_retry_stderr" ]; then
            rm -f "$_cmux_codex_retry_stderr" 2>/dev/null || true
          fi
        }
        trap '_cmux_codex_retry_cleanup; exit 130' INT TERM
        trap '_cmux_codex_retry_cleanup' EXIT
        _cmux_codex_retry_attempt=1
        _cmux_codex_retry_limit=\(maxAttempts)
        while true; do
          _cmux_codex_retry_stderr="$(mktemp "${TMPDIR:-/tmp}/cmux-codex-resume.XXXXXX")" || exit 1
          _cmux_codex_retry_pipe="${_cmux_codex_retry_stderr}.pipe"
          mkfifo "$_cmux_codex_retry_pipe" || exit 1
          # Mirror the wrapped command's stderr to the terminal in full, but retain only
          # the first 64 KiB for lock detection. `codex resume`/`fork` are long-lived
          # interactive sessions, so capturing the whole stderr stream would grow this
          # temp file (and the read below) without bound; the lock diagnostics are emitted
          # at startup, well within the retained prefix. `cat >/dev/null` drains the tail so
          # the mirror never receives SIGPIPE after `head` stops.
          tee /dev/stderr <"$_cmux_codex_retry_pipe" | { head -c 65536 >"$_cmux_codex_retry_stderr" 2>/dev/null; cat >/dev/null; } &
          _cmux_codex_retry_tee_pid=$!
          { \(command); } 2>"$_cmux_codex_retry_pipe"
          _cmux_codex_retry_status=$?
          wait "$_cmux_codex_retry_tee_pid" 2>/dev/null || true
          _cmux_codex_retry_output="$(cat "$_cmux_codex_retry_stderr" 2>/dev/null)"
          rm -f "$_cmux_codex_retry_stderr" "$_cmux_codex_retry_pipe" 2>/dev/null || true
          _cmux_codex_retry_stderr=""
          _cmux_codex_retry_pipe=""
          if [ "$_cmux_codex_retry_status" -eq 0 ]; then
            exit 0
          fi
          if [ "$_cmux_codex_retry_attempt" -ge "$_cmux_codex_retry_limit" ]; then
            exit "$_cmux_codex_retry_status"
          fi
          case "$_cmux_codex_retry_output" in
            *"database is locked"*|*"another Codex process is using its local data"*|*"failed to initialize sqlite state db"*) ;;
            *) exit "$_cmux_codex_retry_status" ;;
          esac
          case "$_cmux_codex_retry_attempt" in
            1) _cmux_codex_retry_delay="0.$((150 + (RANDOM % 100)))" ;;
            2) _cmux_codex_retry_delay="0.$((300 + (RANDOM % 150)))" ;;
            *) _cmux_codex_retry_delay="0.$((600 + (RANDOM % 250)))" ;;
          esac
          sleep "$_cmux_codex_retry_delay"
          _cmux_codex_retry_attempt=$((_cmux_codex_retry_attempt + 1))
        done
        """
    }
}
