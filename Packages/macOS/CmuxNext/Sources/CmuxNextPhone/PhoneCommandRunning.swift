public import Foundation

/// The finished output of one short command (`simctl list`, `simctl io screenshot`).
public struct PhoneCommandResult: Sendable, Hashable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String

    public init(status: Int32, stdout: Data = Data(), stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// A long command that runs until it is told to stop (a screen recording, a
/// log stream). `interrupt()` sends SIGINT, which makes `simctl` and
/// `devicectl` finalize the file they write.
public protocol PhoneRunningCommand: Sendable {
    func interrupt() async
    /// The exit status, once the process has ended (or was killed at `deadline`).
    func waitForExit(deadline: Duration) async -> Int32
}

/// Runs the Xcode command-line tools. Tests inject a fake that records argv.
public protocol PhoneCommandRunning: Sendable {
    /// Runs `arguments` under `/usr/bin/xcrun` to the end. `stdin` is written
    /// and closed first. The process is killed at `deadline`.
    func run(_ arguments: [String], stdin: Data?, deadline: Duration) async throws -> PhoneCommandResult
    /// Starts `arguments` under `/usr/bin/xcrun` and returns at once. Stdout
    /// goes to `stdoutFile` when given (a log stream), else is discarded.
    func start(_ arguments: [String], stdoutFile: URL?) async throws -> any PhoneRunningCommand
}

extension PhoneCommandRunning {
    public func run(_ arguments: [String], deadline: Duration = .seconds(30)) async throws -> PhoneCommandResult {
        try await run(arguments, stdin: nil, deadline: deadline)
    }
}
