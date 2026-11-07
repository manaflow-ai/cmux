public import Foundation

/// The app's diagnostic launch knobs that the daemon reads under its own names.
///
/// The app unsets every inherited `CMUX*` variable that is not a `CMUX_NEXT_*` launch knob
/// (`LaunchIdentity.stripInheritedEnvironment`), so a daemon variable set on the app's launch
/// never reached the daemon: `CMUX_TRACE_FLOWS` and `CMUX_TUI_DEBUG_SPANS` were stripped and the
/// daemon recorded nothing. A harness sets the `CMUX_NEXT_` name on the app; the daemon launch
/// passes the value on under the daemon's name, and the daemon's terminal hosts and holder inherit it.
///
/// ```swift
/// let knobs = DaemonDiagnosticKnobs(processEnvironment: ProcessInfo.processInfo.environment)
/// knobs.daemonEnvironment // ["CMUX_TRACE_FLOWS": "/tmp/flows"] for CMUX_NEXT_TRACE_FLOWS=/tmp/flows
/// ```
public nonisolated struct DaemonDiagnosticKnobs: Sendable, Equatable {
    /// The daemon variables to set, from the knobs present and non-empty in the app's environment
    /// (cmux-daemon-launch-core `diagnostic_knobs`: key-press flow marks, the create-path debug timing marks,
    /// the terminal host model and the R-DAEMON-STATE stage S1 input lane switch). None when the library does
    /// not answer: the daemon then runs with its defaults.
    public let daemonEnvironment: [String: String]

    /// Reads the knobs from `processEnvironment` (the app's environment after its launch strip).
    public init(processEnvironment: [String: String]) {
        daemonEnvironment = DaemonLaunchRules.call("diagnostic_knobs", DaemonLaunchRules.Environment(environment: processEnvironment),
                                                   as: [String: String].self) ?? [:]
    }
}
