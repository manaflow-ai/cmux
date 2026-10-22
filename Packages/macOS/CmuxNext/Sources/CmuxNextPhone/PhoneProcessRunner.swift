public import Foundation

/// The real ``PhoneCommandRunning``: `/usr/bin/xcrun` children by default,
/// or, with no launcher, children whose first argument is the tool's path
/// (``AndroidPhoneBackend`` runs the SDK's `adb` and `emulator` that way).
///
/// With a `developerDirectory` source (the app passes ``XcodeLocator``), every
/// command runs with `DEVELOPER_DIR` set to the installed Xcode, and fails
/// with ``PhoneError/missingTool(_:)`` without starting anything when there is
/// none: on a Mac without developer tools `xcrun` would pop up macOS's
/// command line tools installer, which has no simulators.
public struct PhoneProcessRunner: PhoneCommandRunning, PhoneStreamingRunning {
    private let launcher: URL?
    private let developerDirectory: (@Sendable () -> String?)?

    /// - Parameters:
    ///   - launcher: the program that runs every command; nil runs `arguments[0]`.
    ///   - developerDirectory: the Xcode to run under (nil from it: Xcode is missing). Nil leaves
    ///     the environment as it is (Android tools, tests).
    public init(launcher: URL? = URL(fileURLWithPath: "/usr/bin/xcrun"), developerDirectory: (@Sendable () -> String?)? = nil) {
        self.launcher = launcher
        self.developerDirectory = developerDirectory
    }

    public func run(_ arguments: [String], stdin: Data?, deadline: Duration) async throws -> PhoneCommandResult {
        let process = try PhoneProcess(launcher: launcher, arguments: arguments, stdin: stdin, stdoutFile: nil, captureStdout: true,
                                       environment: try environment())
        let status = await process.waitForExit(deadline: deadline)
        return PhoneCommandResult(status: status, stdout: process.stdout, stderr: process.stderr)
    }

    public func start(_ arguments: [String], stdoutFile: URL?) async throws -> any PhoneRunningCommand {
        try PhoneProcess(launcher: launcher, arguments: arguments, stdin: nil, stdoutFile: stdoutFile, captureStdout: false,
                         environment: try environment())
    }

    public func stream(_ arguments: [String]) -> AsyncThrowingStream<PhoneOutputEvent, any Error> {
        let (events, continuation) = AsyncThrowingStream<PhoneOutputEvent, any Error>.makeStream(bufferingPolicy: .bufferingNewest(256))
        do {
            let process = try PhoneProcess(launcher: launcher, arguments: arguments, stdin: nil, stdoutFile: nil, captureStdout: true,
                                           environment: try environment(),
                                           onOutput: { continuation.yield(.output(String(decoding: $0, as: UTF8.self))) })
            // task-owner: the stream; it ends when the process exits, and cancelling the consumer interrupts the process.
            let waiter = Task {
                let status = await process.waitForExit(deadline: .seconds(6 * 60 * 60))
                continuation.yield(.exited(status, stderr: process.stderr))
                continuation.finish()
            }
            continuation.onTermination = { reason in
                guard case .cancelled = reason else { return }
                waiter.cancel()
                // task-owner: one SIGINT to a process the cancelled stream owned; it ends with the process.
                Task { await process.interrupt() }
            }
        } catch {
            continuation.finish(throwing: error)
        }
        return events
    }

    private func environment() throws -> [String: String] {
        guard let developerDirectory else { return [:] }
        guard let developer = developerDirectory() else { throw PhoneError.missingTool(.xcode) }
        return ["DEVELOPER_DIR": developer]
    }
}
