@testable import CmuxNextDaemon

extension DaemonBridge {
    /// A test bridge that runs a Python script in place of `cmux link dial`:
    /// `/usr/bin/python3 -u ARGUMENTS`, started through `/usr/bin/env -u SWIFT_BACKTRACE`.
    ///
    /// The swift test wrapper exports `SWIFT_BACKTRACE=enable=yes,…` (#25857) so a
    /// crashing test prints a backtrace. Every child inherits it, and on macOS a
    /// privileged executable such as `/usr/bin/python3` then writes
    /// "swift runtime: backtrace-on-crash is not supported for privileged executables."
    /// to stderr before the script starts. That line came first, so the bridge's
    /// dial check read it as the dial reply and threw "the link dial's answer is not
    /// JSON". Dropping the variable for the child keeps the test process's own
    /// backtraces.
    static func fakePython(_ arguments: [String]) -> DaemonBridge {
        DaemonBridge(executable: "/usr/bin/env", arguments: ["-u", "SWIFT_BACKTRACE", "/usr/bin/python3", "-u"] + arguments)
    }
}
