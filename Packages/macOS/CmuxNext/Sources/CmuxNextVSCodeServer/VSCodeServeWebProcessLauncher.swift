public import CmuxNextWakeups
import Foundation

/// Runs the real `serve-web` binary and waits for its `Web UI available at <url>` line.
///
/// The server's standard output and error share one pipe, drained for the whole life of the
/// process so its logging never blocks it. The spawn runs on a ``ProcessLauncher`` queue, never
/// the caller's actor, and the server at the launcher's priority's `processQoS`.
public struct VSCodeServeWebProcessLauncher: VSCodeServeWebLaunching {
    private let startupTimeout: Duration
    private let launcher: ProcessLauncher

    /// Creates a launcher.
    /// - Parameters:
    ///   - startupTimeout: How long a server may take to print its URL. A first run
    ///     downloads the server, so the default is a minute (classic cmux's deadline).
    ///   - launcher: Spawns the server. The default runs the spawn and the server at
    ///     ``WorkPriority/userVisible``: the editor tab that waits for it is on screen.
    public init(startupTimeout: Duration = .seconds(60),
                launcher: ProcessLauncher = ProcessLauncher(label: "com.cmuxterm.next.vscode-serve-web", priority: .userVisible)) {
        self.startupTimeout = startupTimeout
        self.launcher = launcher
    }

    /// Starts `launch`; see ``VSCodeServeWebLaunching/start(_:)``.
    public func start(_ launch: VSCodeServeWebLaunch) async throws -> VSCodeServeWebStarted {
        let process = Process()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = ServeWebProcess(process: process, pipe: pipe)
        do {
            try await launcher.launched(process)
        } catch {
            throw VSCodeServeWebError.launchFailed(error.localizedDescription)
        }
        // The first of the URL line, the output ending, the startup deadline and cancellation
        // resumes the wait once (no task group waits for a loser).
        let outcome = FirstOutcome<Result<URL, VSCodeServeWebError>>()
        drain(fileDescriptor: pipe.fileHandleForReading.fileDescriptor, into: outcome)
        // timer-class-allow: off-main: the startup bound only resolves `outcome` (thread-safe) and posts no main-thread job
        let deadline = DemandTimer(owner: "vscode-serve-web.startup")
        deadline.schedule(after: startupTimeout) { outcome.resolve(.failure(.startupTimedOut)) }
        let result = await withTaskCancellationHandler {
            await outcome.value()
        } onCancel: {
            outcome.resolve(.failure(.stopped))
            handle.terminate()
        }
        deadline.cancel()
        do {
            try Task.checkCancellation()
            let url = try result.get()
            return VSCodeServeWebStarted(handle: handle, url: url)
        } catch {
            handle.terminate()
            throw error
        }
    }

    /// Reads the server's output until it ends: the first Web UI URL it prints resolves
    /// `outcome`, and the end of the output before one does resolves it as exited.
    private func drain(fileDescriptor: Int32, into outcome: FirstOutcome<Result<URL, VSCodeServeWebError>>) {
        // task-owner: drains the server's output for the life of the process; it ends at EOF.
        Task.detached {
            let reader = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
            var found = false
            do {
                for try await line in reader.bytes.lines where !found {
                    if let url = URL(vscodeServeWebOutput: line) {
                        found = true
                        outcome.resolve(.success(url))
                    }
                }
            } catch {}
            outcome.resolve(.failure(.exitedBeforeReady))
        }
    }
}
