/// Builds the signal-aware sleep lifecycle shared by SSH retry entrypoints.
///
/// Initial startup and persistent PTY attach use different surrounding state
/// machines, but both must track a background timer and close the signal race
/// between spawning that timer and recording its PID. Attach retries also own
/// a muted terminal phase so detached input is discarded at the boundary.
public struct SSHRetryBackoffScriptBuilder: Sendable {
    private let variablePrefix: String
    private let signalHandler: String
    private let signalStatusVariable: String
    private let signalNameVariable: String
    private let delayVariable: String
    private let pausesTerminalInput: Bool

    /// Creates a builder for one SSH retry entrypoint.
    public init(context: SSHRetryBackoffContext) {
        switch context {
        case .startup:
            variablePrefix = "CMUX_SSH"
            signalHandler = "cmux_ssh_signal_exit"
            signalStatusVariable = "cmux_ssh_signal_status"
            signalNameVariable = "cmux_ssh_signal_name"
            delayVariable = "cmux_ssh_reconnect_delay"
            pausesTerminalInput = false
        case .attach:
            variablePrefix = "cmux_ssh_attach"
            signalHandler = "cmux_ssh_attach_signal_exit"
            signalStatusVariable = "cmux_ssh_attach_signal_status"
            signalNameVariable = "cmux_ssh_attach_signal_name"
            delayVariable = "cmux_ssh_attach_reconnect_delay"
            pausesTerminalInput = true
        }
    }

    /// Shell state that must be initialized before the retry loop begins.
    public var stateInitializationLines: [String] {
        var lines = [
            "\(backoffPIDVariable)=",
            "\(backoffLaunchingVariable)=0",
            "\(pendingSignalVariable)=",
            "\(pendingSignalNameVariable)=",
        ]
        if pausesTerminalInput {
            lines += [
                "cmux_ssh_attach_terminal_state=\"$(/bin/stty -g <&0 2>/dev/null || true)\"",
                "cmux_ssh_attach_input_paused=0",
            ]
        }
        return lines
    }

    /// `elif` branches inserted after higher-priority child cleanup in a signal handler.
    public var signalHandlerBranches: String {
        "elif [ -n \"${\(backoffPIDVariable):-}\" ]; then /bin/kill -TERM \"$\(backoffPIDVariable)\" >/dev/null 2>&1 || true; wait \"$\(backoffPIDVariable)\" 2>/dev/null || true; \(terminalInputRestoreLine) \(backoffPIDVariable)=; elif [ \"${\(backoffLaunchingVariable):-0}\" = 1 ]; then \(pendingSignalVariable)=\"$\(signalStatusVariable)\"; \(pendingSignalNameVariable)=\"$\(signalNameVariable)\"; return;"
    }

    /// Shell line that restores traditional terminal input before a retry prompt.
    public var terminalInputModeResetLine: String {
        "if [ -t 2 ]; then printf '\\033[?1004l\\033[>m\\033[<8u' >&2 || true; fi"
    }

    /// Shell lines that wait while managed attach retries discard terminal input
    /// and retire promptly on signals.
    public var waitLines: [String] {
        var lines = [
            "  if [ \"$\(delayVariable)\" -gt 0 ]; then",
            "    \(backoffLaunchingVariable)=1",
            "    sleep \"$\(delayVariable)\" &",
            "    \(backoffPIDVariable)=$!",
            "    \(backoffLaunchingVariable)=0",
            "    if [ -n \"${\(pendingSignalVariable):-}\" ]; then \(signalHandler) \"$\(pendingSignalVariable)\" \"${\(pendingSignalNameVariable):-TERM}\"; fi",
            "    wait \"$\(backoffPIDVariable)\" 2>/dev/null || true",
            pausesTerminalInput ? "    \(terminalInputRestoreLine)" : nil,
            "    \(backoffPIDVariable)=",
            "  fi",
        ].compactMap { $0 }
        if pausesTerminalInput {
            lines.insert(contentsOf: [
                "    if [ -t 0 ] && [ -n \"${cmux_ssh_attach_terminal_state:-}\" ] && [ -n \"${cmux_ssh_attach_cli:-}\" ]; then",
                "      cmux_ssh_attach_input_paused=1",
                "      if ! /bin/stty -echo -icanon isig min 1 time 0 <&0 2>/dev/null; then cmux_ssh_attach_input_paused=0; fi",
                "      if [ \"${cmux_ssh_attach_input_paused:-0}\" = 1 ]; then \"$cmux_ssh_attach_cli\" __ssh-pty-flush-input <&0 >/dev/null 2>&1 || true; fi",
                "    fi",
            ], at: 1)
        }
        return lines
    }

    private var terminalInputRestoreLine: String {
        pausesTerminalInput
            ? "if [ \"${cmux_ssh_attach_input_paused:-0}\" = 1 ]; then cmux_ssh_attach_restore_terminal; fi;"
            : ""
    }

    private var backoffPIDVariable: String { "\(variablePrefix)_backoff_pid" }
    private var backoffLaunchingVariable: String { "\(variablePrefix)_backoff_launching" }
    private var pendingSignalVariable: String { "\(variablePrefix)_pending_signal" }
    private var pendingSignalNameVariable: String { "\(variablePrefix)_pending_signal_name" }
}
