/// Builds the signal-aware sleep lifecycle shared by SSH retry entrypoints.
///
/// Initial startup and persistent PTY attach use different surrounding state
/// machines, but both must track a background timer, preserve terminal input,
/// and close the signal race between spawning that timer and recording its PID.
public struct SSHRetryBackoffScriptBuilder: Sendable {
    private let variablePrefix: String
    private let signalHandler: String
    private let signalStatusVariable: String
    private let signalNameVariable: String
    private let delayVariable: String

    /// Creates a builder for one SSH retry entrypoint.
    public init(context: SSHRetryBackoffContext) {
        switch context {
        case .startup:
            variablePrefix = "CMUX_SSH"
            signalHandler = "cmux_ssh_signal_exit"
            signalStatusVariable = "cmux_ssh_signal_status"
            signalNameVariable = "cmux_ssh_signal_name"
            delayVariable = "cmux_ssh_reconnect_delay"
        case .attach:
            variablePrefix = "cmux_ssh_attach"
            signalHandler = "cmux_ssh_attach_signal_exit"
            signalStatusVariable = "cmux_ssh_attach_signal_status"
            signalNameVariable = "cmux_ssh_attach_signal_name"
            delayVariable = "cmux_ssh_attach_reconnect_delay"
        }
    }

    /// Shell state that must be initialized before the retry loop begins.
    public var stateInitializationLines: [String] {
        [
            "\(backoffPIDVariable)=",
            "\(backoffLaunchingVariable)=0",
            "\(pendingSignalVariable)=",
            "\(pendingSignalNameVariable)=",
        ]
    }

    /// `elif` branches inserted after higher-priority child cleanup in a signal handler.
    public var signalHandlerBranches: String {
        "elif [ -n \"${\(backoffPIDVariable):-}\" ]; then /bin/kill -TERM \"$\(backoffPIDVariable)\" >/dev/null 2>&1 || true; wait \"$\(backoffPIDVariable)\" 2>/dev/null || true; \(backoffPIDVariable)=; elif [ \"${\(backoffLaunchingVariable):-0}\" = 1 ]; then \(pendingSignalVariable)=\"$\(signalStatusVariable)\"; \(pendingSignalNameVariable)=\"$\(signalNameVariable)\"; return;"
    }

    /// Shell line that restores traditional terminal input before a retry prompt.
    public var terminalInputModeResetLine: String {
        "if [ -t 2 ]; then printf '\\033[?1004l\\033[>m\\033[<8u' >&2 || true; fi"
    }

    /// Shell lines that wait without consuming terminal input and retire promptly on signals.
    public var waitLines: [String] {
        [
            "  if [ \"$\(delayVariable)\" -gt 0 ]; then",
            "    \(backoffLaunchingVariable)=1",
            "    sleep \"$\(delayVariable)\" &",
            "    \(backoffPIDVariable)=$!",
            "    \(backoffLaunchingVariable)=0",
            "    if [ -n \"${\(pendingSignalVariable):-}\" ]; then \(signalHandler) \"$\(pendingSignalVariable)\" \"${\(pendingSignalNameVariable):-TERM}\"; fi",
            "    wait \"$\(backoffPIDVariable)\" 2>/dev/null || true",
            "    \(backoffPIDVariable)=",
            "  fi",
        ]
    }

    private var backoffPIDVariable: String { "\(variablePrefix)_backoff_pid" }
    private var backoffLaunchingVariable: String { "\(variablePrefix)_backoff_launching" }
    private var pendingSignalVariable: String { "\(variablePrefix)_pending_signal" }
    private var pendingSignalNameVariable: String { "\(variablePrefix)_pending_signal_name" }
}
