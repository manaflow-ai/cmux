import Foundation

enum SSHPTYAttachRetryLoop {
    private static let healthyBridgeUptime: TimeInterval = 30

    static func bridgeClosureMadeNoProgress(
        receivedOutput: Bool,
        bridgeUptime: TimeInterval
    ) -> Bool {
        // A bridge that remains connected through an ordinary idle interval is
        // healthy even when the remote shell has not emitted output.
        !receivedOutput && bridgeUptime >= 0 && bridgeUptime < healthyBridgeUptime
    }

    static func hasNoProgressRetryRemaining(currentRetry: Int, limit: Int) -> Bool {
        currentRetry >= 0 && limit > 0 && currentRetry + 1 < limit
    }

    static func lines(command: String, reauthenticates: Bool) -> [String] {
        let reauthenticate = reauthenticates ? "cmux_ssh_attach_reauth_required=1" : ":"
        let reattachingFormat = shellQuote(
            String(
                localized: "cli.sshPtyAttach.bridgeClosedReattaching",
                defaultValue: "[cmux] remote PTY bridge closed; reattaching (attempt %s/%s)."
            )
        )
        let noProgressFormat = shellQuote(
            String(
                localized: "cli.sshPtyAttach.noProgressRetryLimitReached",
                defaultValue: "[cmux] remote PTY bridge made no progress after %s attempts; stopping retries."
            )
        )
        let noProgressStatus = SSHPTYAttachExitCode.bridgeClosedWithoutProgress.rawValue

        return [
            "cmux_ssh_attach_reconnect_limit=\"${CMUX_SSH_RECONNECT_LIMIT:-}\"",
            "case \"$cmux_ssh_attach_reconnect_limit\" in '') cmux_ssh_attach_reconnect_limit='∞'; cmux_ssh_attach_reconnect_unbounded=1 ;; *[!0-9]*) cmux_ssh_attach_reconnect_limit=20; cmux_ssh_attach_reconnect_unbounded=0 ;; *) cmux_ssh_attach_reconnect_unbounded=0 ;; esac",
            "cmux_ssh_attach_reconnect_delay=\"${CMUX_SSH_RECONNECT_DELAY_SECONDS:-2}\"",
            "case \"$cmux_ssh_attach_reconnect_delay\" in ''|*[!0-9]*|0*) cmux_ssh_attach_reconnect_delay=2 ;; esac",
            "cmux_ssh_attach_reconnect_max_delay=\"${CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS:-30}\"",
            "case \"$cmux_ssh_attach_reconnect_max_delay\" in ''|*[!0-9]*|0*) cmux_ssh_attach_reconnect_max_delay=30 ;; esac",
            "if [ \"$cmux_ssh_attach_reconnect_delay\" -gt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_max_delay\"; fi",
            "cmux_ssh_attach_reconnect_initial_delay=\"$cmux_ssh_attach_reconnect_delay\"",
            "cmux_ssh_attach_no_progress_limit=\"${CMUX_SSH_PTY_NO_PROGRESS_RETRY_LIMIT:-3}\"",
            "case \"$cmux_ssh_attach_no_progress_limit\" in ''|*[!0-9]*|0*) cmux_ssh_attach_no_progress_limit=3 ;; esac",
            "cmux_ssh_attach_no_progress_retry=0",
            "cmux_ssh_attach_retry=0",
            "cmux_ssh_attach_reauth_required=0",
            "while :; do",
            "  if [ \"$cmux_ssh_attach_reauth_required\" -eq 1 ]; then",
            "    cmux_ssh_attach_foreground_auth",
            "    cmux_ssh_attach_status=$?",
            "    if [ \"$cmux_ssh_attach_status\" -eq 0 ]; then cmux_ssh_attach_reauth_required=0; elif [ \"$cmux_ssh_attach_status\" -ne 255 ]; then exit \"$cmux_ssh_attach_status\"; fi",
            "  fi",
            "  if [ \"$cmux_ssh_attach_reauth_required\" -eq 0 ]; then",
            "  if [ \"$cmux_ssh_attach_reconnect_unbounded\" -eq 1 ] || [ \"$cmux_ssh_attach_retry\" -lt \"$cmux_ssh_attach_reconnect_limit\" ]; then cmux_ssh_attach_can_retry=1; else cmux_ssh_attach_can_retry=0; fi",
            "  CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY=\"$cmux_ssh_attach_can_retry\" CMUX_SSH_PTY_ATTACH_NO_PROGRESS_RETRY=\"$cmux_ssh_attach_no_progress_retry\" CMUX_SSH_PTY_ATTACH_NO_PROGRESS_LIMIT=\"$cmux_ssh_attach_no_progress_limit\" \(command)",
            "  cmux_ssh_attach_status=$?",
            "  case \"$cmux_ssh_attach_status\" in",
            "    \(noProgressStatus)) cmux_ssh_attach_no_progress_retry=$((cmux_ssh_attach_no_progress_retry + 1)); cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_initial_delay\"; if [ \"$cmux_ssh_attach_no_progress_retry\" -ge \"$cmux_ssh_attach_no_progress_limit\" ]; then printf '\\n\\033[31m%s\\033[0m\\n' \"$(printf \(noProgressFormat) \"$cmux_ssh_attach_no_progress_limit\")\" >&2 || true; exit 1; fi ;;",
            "    254) cmux_ssh_attach_no_progress_retry=0; cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_initial_delay\" ;;",
            "    255) cmux_ssh_attach_no_progress_retry=0; \(reauthenticate) ;;",
            "    *) exit \"$cmux_ssh_attach_status\" ;;",
            "  esac",
            "  fi",
            "  if [ \"$cmux_ssh_attach_reconnect_unbounded\" -eq 0 ] && [ \"$cmux_ssh_attach_retry\" -ge \"$cmux_ssh_attach_reconnect_limit\" ]; then exit \"$cmux_ssh_attach_status\"; fi",
            "  cmux_ssh_attach_retry=$((cmux_ssh_attach_retry + 1))",
            "  if [ -t 2 ]; then printf '\\n\\033[33m%s\\033[0m\\n' \"$(printf \(reattachingFormat) \"$cmux_ssh_attach_retry\" \"$cmux_ssh_attach_reconnect_limit\")\" >&2 || true; fi",
            "  if [ \"$cmux_ssh_attach_reconnect_delay\" -gt 0 ]; then sleep \"$cmux_ssh_attach_reconnect_delay\"; fi",
            "  if [ \"$cmux_ssh_attach_reconnect_delay\" -lt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=$((cmux_ssh_attach_reconnect_delay * 2)); if [ \"$cmux_ssh_attach_reconnect_delay\" -gt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_max_delay\"; fi; fi",
            "done",
        ]
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
