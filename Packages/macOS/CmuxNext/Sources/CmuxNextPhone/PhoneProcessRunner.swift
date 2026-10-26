public import CmuxNextWakeups
public import Foundation

/// The real ``PhoneCommandRunning``: `/usr/bin/xcrun` children by default,
/// or, with no launcher, children whose first argument is the tool's path
/// (``AndroidPhoneBackend`` runs the SDK's `adb` and `emulator` that way).
public struct PhoneProcessRunner: PhoneCommandRunning {
    private let launcher: URL?
    private let processLauncher: ProcessLauncher?

    /// - Parameters:
    ///   - launcher: the program that runs every command; nil runs `arguments[0]`.
    ///   - processLauncher: spawns the children; nil spawns each on its own queue at the caller's priority,
    ///     the child at ``WorkPriority/userVisible`` for its whole life (a long `emulator` never runs at the
    ///     priority of the click that started it).
    public init(launcher: URL? = URL(fileURLWithPath: "/usr/bin/xcrun"), processLauncher: ProcessLauncher? = nil) {
        self.launcher = launcher
        self.processLauncher = processLauncher
    }

    public func run(_ arguments: [String], stdin: Data?, deadline: Duration) async throws -> PhoneCommandResult {
        let process = try await PhoneProcess.launch(launcher: launcher, arguments: arguments, stdin: stdin, stdoutFile: nil,
                                                    captureStdout: true, spawner: spawner())
        let status = await process.waitForExit(deadline: deadline)
        return PhoneCommandResult(status: status, stdout: process.stdout, stderr: process.stderr)
    }

    public func start(_ arguments: [String], stdoutFile: URL?) async throws -> any PhoneRunningCommand {
        try await PhoneProcess.launch(launcher: launcher, arguments: arguments, stdin: nil, stdoutFile: stdoutFile,
                                      captureStdout: false, spawner: spawner())
    }

    private func spawner() -> ProcessLauncher {
        processLauncher ?? ProcessLauncher(label: "com.cmuxterm.next.phone-process", priority: WorkPriority(Task.currentPriority),
                                           childPriority: .userVisible)
    }
}
