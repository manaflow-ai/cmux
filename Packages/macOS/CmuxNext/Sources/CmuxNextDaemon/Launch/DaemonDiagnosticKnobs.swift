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
    /// App launch knob to daemon variable: key-press flow marks (scripts/cmux-next/trace.py), the
    /// create-path debug timing marks, and the terminal host model (`holder`: the install's one holder
    /// instead of a host process per terminal; scripts/cmux-next/holder-dogfood.py, default off).
    public static let names: [(app: String, daemon: String)] = [
        ("CMUX_NEXT_TRACE_FLOWS", "CMUX_TRACE_FLOWS"),
        ("CMUX_NEXT_TUI_DEBUG_SPANS", "CMUX_TUI_DEBUG_SPANS"),
        ("CMUX_NEXT_TUI_TERMINAL_HOST_MODEL", "CMUX_TUI_TERMINAL_HOST_MODEL"),
    ]

    /// The daemon variables to set, from the knobs present and non-empty in the app's environment.
    public let daemonEnvironment: [String: String]

    /// Reads the knobs from `processEnvironment` (the app's environment after its launch strip).
    public init(processEnvironment: [String: String]) {
        var environment: [String: String] = [:]
        for (app, daemon) in Self.names {
            if let value = processEnvironment[app], !value.isEmpty { environment[daemon] = value }
        }
        daemonEnvironment = environment
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.daemonEnvironment == rhs.daemonEnvironment }
}
