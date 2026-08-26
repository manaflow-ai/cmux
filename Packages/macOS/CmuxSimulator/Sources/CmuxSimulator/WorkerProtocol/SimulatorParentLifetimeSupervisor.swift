import Foundation

private let simulatorParentLifetimeSupervisorScript = #"""
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

/// The shell executable used to host the parent-lifetime supervisor.
package let simulatorParentLifetimeSupervisorExecutableURL =
    URL(fileURLWithPath: "/bin/sh")

/// Wraps one command in a dedicated process-group leader whose stdin stays
/// connected to its parent. EOF kills the complete process group.
package func simulatorParentLifetimeSupervisorArguments(
    executableURL: URL,
    arguments: [String]
) -> [String] {
    [
        "-c",
        simulatorParentLifetimeSupervisorScript,
        "cmux-simulator-command-supervisor",
        executableURL.path,
    ] + arguments
}
