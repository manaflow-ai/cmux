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

    /// Wraps a rendered Codex command in a retrying `/bin/zsh -c` launcher.
    ///
    /// - Parameters:
    ///   - command: The already shell-rendered Codex command to execute.
    ///   - quote: A shell quoting function for the generated zsh script.
    /// - Returns: `command` unchanged when retries are disabled; otherwise a shell command that
    ///   retries transient Codex state database lock failures during startup.
    public func wrappedCommand(_ command: String, quote: (String) -> String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxAttempts > 1, !trimmed.isEmpty else { return command }
        guard !trimmed.contains("_cmux_codex_retry_limit") else { return trimmed }
        return "/bin/zsh -c \(quote(retryScript(command: trimmed)))"
    }

    /// Renders the retry loop as a **single-line** POSIX script.
    ///
    /// The wrapper emits `/bin/zsh -c '<script>'`, and that whole command is copy-pasted into — and
    /// dispatched through — the user's login shell, which may be csh/tcsh (a supported restore path,
    /// https://github.com/manaflow-ai/cmux/issues/5639). csh/tcsh reject a single-quoted argument that
    /// contains literal newlines ("Unmatched '") before `/bin/zsh` ever starts, so the statements are
    /// joined with `;` rather than newlines and must stay on one line. Do not reformat this into a
    /// multi-line `"""` heredoc.
    private func retryScript(command: String) -> String {
        // Each attempt captures stderr through a FIFO to detect the lock diagnostics. `tee /dev/stderr`
        // still mirrors every byte to the terminal; only the first 64 KiB is retained for detection so a
        // verbose session cannot grow the temp file (or the exit-time read) without bound, and
        // `cat >/dev/null` drains the tail so the mirror never receives SIGPIPE after `head` stops.
        // If Codex lives long enough to plausibly be interactive, the wrapper returns the status instead
        // of relaunching even when stderr happens to contain a lock-looking string.
        let retryAttempt = [
            "_cmux_codex_retry_stderr=\"$(mktemp \"${TMPDIR:-/tmp}/cmux-codex-resume.XXXXXX\")\" || exit 1",
            "_cmux_codex_retry_pipe=\"${_cmux_codex_retry_stderr}.pipe\"",
            "mkfifo \"$_cmux_codex_retry_pipe\" || exit 1",
            "tee /dev/stderr <\"$_cmux_codex_retry_pipe\" | { head -c 65536 >\"$_cmux_codex_retry_stderr\" 2>/dev/null; cat >/dev/null; } & _cmux_codex_retry_tee_pid=$!",
            "_cmux_codex_retry_started=$SECONDS",
            "{ \(command); } 2>\"$_cmux_codex_retry_pipe\"",
            "_cmux_codex_retry_status=$?",
            "wait \"$_cmux_codex_retry_tee_pid\" 2>/dev/null || true",
            "_cmux_codex_retry_output=\"$(cat \"$_cmux_codex_retry_stderr\" 2>/dev/null)\"",
            "rm -f \"$_cmux_codex_retry_stderr\" \"$_cmux_codex_retry_pipe\" 2>/dev/null || true",
            "_cmux_codex_retry_stderr=\"\"",
            "_cmux_codex_retry_pipe=\"\"",
            "[ \"$_cmux_codex_retry_status\" -eq 0 ] && exit 0",
            "[ \"$((SECONDS - _cmux_codex_retry_started))\" -ge 3 ] && exit \"$_cmux_codex_retry_status\"",
            "case \"$_cmux_codex_retry_output\" in *\"database is locked\"*|*\"another Codex process is using its local data\"*) ;; *) exit \"$_cmux_codex_retry_status\" ;; esac",
        ].joined(separator: "; ")
        let afterAttempt = [
            "[ \"$_cmux_codex_retry_attempt\" -ge \"$_cmux_codex_retry_limit\" ] && exit \"$_cmux_codex_retry_status\"",
            "_cmux_codex_retry_attempt=$((_cmux_codex_retry_attempt + 1))",
        ].joined(separator: "; ")
        let loopBody = "\(retryAttempt); \(afterAttempt)"
        let cleanup = "_cmux_codex_retry_cleanup() { if [ -n \"$_cmux_codex_retry_pipe\" ]; then rm -f \"$_cmux_codex_retry_pipe\" 2>/dev/null || true; fi; if [ -n \"$_cmux_codex_retry_stderr\" ]; then rm -f \"$_cmux_codex_retry_stderr\" 2>/dev/null || true; fi; }"
        return [
            "_cmux_codex_retry_stderr=\"\"",
            "_cmux_codex_retry_pipe=\"\"",
            cleanup,
            "trap '_cmux_codex_retry_cleanup; exit 130' INT TERM",
            "trap '_cmux_codex_retry_cleanup' EXIT",
            "_cmux_codex_retry_attempt=1",
            "_cmux_codex_retry_limit=\(maxAttempts)",
            "while true; do \(loopBody); done",
        ].joined(separator: "; ")
    }
}
