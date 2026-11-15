public import Foundation

// `shell-runs-v1` (cmux-tui `crates/cmux-tui-core/src/shell_runs.rs`, `server/shell_wire.rs`):
// shell mode's commands of a chat on another machine run there, on its daemon. A refusal is an
// answer (`refused`), so its code reaches the app also over a remote link.

/// `shell-run {command, cwd?, scope?, run?}`: starts `command` in `cwd` there under the id `run`
/// (chosen here, so a start whose answer is lost can still be stopped); `{run}` or `{refused}`.
public nonisolated struct ShellRunRequest: DaemonRequest {
    public static let command = "shell-run"
    public static let requiredCapability: String? = "shell-runs-v1"

    public let command: String
    public let cwd: String?
    public let scope: String
    public let run: String?

    public init(command: String, cwd: String?, scope: String, run: String? = nil) {
        self.command = command
        self.cwd = cwd
        self.scope = scope
        self.run = run
    }

    /// A new run id in the daemon's form: `run_` and 32 lowercase hex digits (128 random bits).
    public static func newRunID() -> String {
        var generator = SystemRandomNumberGenerator()
        return "run_" + (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    public nonisolated struct Response: Decodable, Sendable, Equatable {
        public let run: String?
        public let refused: String?
    }
}

/// `shell-read {run, after}`: output after `after`, answered when there is some or the command
/// ended, else after 10 s.
public nonisolated struct ShellReadRequest: DaemonRequest {
    public static let command = "shell-read"
    public static let requiredCapability: String? = "shell-runs-v1"
    /// The daemon's long poll plus the link's own time.
    public static let timeout: Duration = .seconds(20)

    public let run: String
    public let after: Int

    public init(run: String, after: Int) {
        self.run = run
        self.after = after
    }

    public nonisolated struct Response: Decodable, Sendable, Equatable {
        public let output: String?
        public let next: Int?
        public let truncated: Bool?
        public let exit: Exit?
        public let refused: String?

        public nonisolated struct Exit: Decodable, Sendable, Equatable {
            public let code: Int32?
            public let signal: Int32?
        }
    }
}

/// `shell-stop {run}`: Ctrl-C to the command's process group, then SIGTERM and SIGKILL.
public nonisolated struct ShellStopRequest: DaemonRequest {
    public static let command = "shell-stop"
    public static let requiredCapability: String? = "shell-runs-v1"

    public let run: String

    public init(run: String) {
        self.run = run
    }

    public nonisolated struct Response: Decodable, Sendable, Equatable {
        public let refused: String?
    }
}
