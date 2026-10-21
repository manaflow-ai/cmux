public import Foundation

/// The real ``PhoneCommandRunning``: `/usr/bin/xcrun` children by default,
/// or, with no launcher, children whose first argument is the tool's path
/// (``AndroidPhoneBackend`` runs the SDK's `adb` and `emulator` that way).
public struct PhoneProcessRunner: PhoneCommandRunning {
    private let launcher: URL?

    /// - Parameter launcher: the program that runs every command; nil runs `arguments[0]`.
    public init(launcher: URL? = URL(fileURLWithPath: "/usr/bin/xcrun")) {
        self.launcher = launcher
    }

    public func run(_ arguments: [String], stdin: Data?, deadline: Duration) async throws -> PhoneCommandResult {
        let process = try PhoneProcess(launcher: launcher, arguments: arguments, stdin: stdin, stdoutFile: nil, captureStdout: true)
        let status = await process.waitForExit(deadline: deadline)
        return PhoneCommandResult(status: status, stdout: process.stdout, stderr: process.stderr)
    }

    public func start(_ arguments: [String], stdoutFile: URL?) async throws -> any PhoneRunningCommand {
        try PhoneProcess(launcher: launcher, arguments: arguments, stdin: nil, stdoutFile: stdoutFile, captureStdout: false)
    }
}
