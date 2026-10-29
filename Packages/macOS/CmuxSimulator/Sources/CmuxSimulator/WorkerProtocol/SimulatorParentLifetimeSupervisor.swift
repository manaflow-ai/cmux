import Foundation

// The shell's own stderr goes to /dev/null and the command gets the original
// on fd 4: /bin/sh is bash, which reports the killed watchdog ("line 7: …
// Killed: 9") on the shell's stderr whenever it reaps it, and that line would
// land in the command's captured output.
private let simulatorParentLifetimeSupervisorScript = #"""
    exec 3<&0 4>&2 2>/dev/null
    (IFS= read -r _ <&3 || kill -KILL 0) 4>&- &
    watchdog=$!
    exec 3<&-
    "$@" </dev/null 2>&4 4>&-
    status=$?
    kill -KILL "$watchdog"
    wait "$watchdog"
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
