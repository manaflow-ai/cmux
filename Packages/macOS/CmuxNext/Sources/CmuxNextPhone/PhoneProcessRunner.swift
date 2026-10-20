public import Foundation

/// The real ``PhoneCommandRunning``: `/usr/bin/xcrun` children.
public struct PhoneProcessRunner: PhoneCommandRunning {
    public init() {}

    public func run(_ arguments: [String], stdin: Data?, deadline: Duration) async throws -> PhoneCommandResult {
        let process = try PhoneProcess(arguments: arguments, stdin: stdin, stdoutFile: nil, captureStdout: true)
        let status = await process.waitForExit(deadline: deadline)
        return PhoneCommandResult(status: status, stdout: process.stdout, stderr: process.stderr)
    }

    public func start(_ arguments: [String], stdoutFile: URL?) async throws -> any PhoneRunningCommand {
        try PhoneProcess(arguments: arguments, stdin: nil, stdoutFile: stdoutFile, captureStdout: false)
    }
}
