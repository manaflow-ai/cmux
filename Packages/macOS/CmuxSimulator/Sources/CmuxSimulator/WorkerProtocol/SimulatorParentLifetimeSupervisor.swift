import Foundation

/// Wraps one command in a dedicated process-group leader whose stdin stays
/// connected to its parent. EOF means the parent died, so the watchdog kills
/// the complete group. Normal command exit preserves the command status and
/// lets `SimulatorProcessGroupProcess` reap any remaining descendants.
package enum SimulatorParentLifetimeSupervisor {
    package static let executableURL = URL(fileURLWithPath: "/bin/sh")

    package static let script = #"""
    exec 3<&0
    (IFS= read -r _ <&3 || kill -KILL 0) &
    watchdog=$!
    exec 3<&-
    "$@" </dev/null
    status=$?
    kill -KILL "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    exit "$status"
    """#

    package static func arguments(
        executableURL: URL,
        arguments: [String]
    ) -> [String] {
        [
            "-c",
            script,
            "cmux-simulator-command-supervisor",
            executableURL.path,
        ] + arguments
    }
}
