import CmuxNextWakeups
import Foundation

/// Runs the real `serve-web` binary and waits for its `Web UI available at <url>` line.
///
/// The server's standard output and error share one pipe, drained for the whole life of the
/// process so its logging never blocks it.
public struct VSCodeServeWebProcessLauncher: VSCodeServeWebLaunching {
    private let startupTimeout: Duration

    /// Creates a launcher.
    /// - Parameter startupTimeout: How long a server may take to print its URL. A first run
    ///   downloads the server, so the default is a minute (classic cmux's deadline).
    public init(startupTimeout: Duration = .seconds(60)) {
        self.startupTimeout = startupTimeout
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
            try process.run()
        } catch {
            throw VSCodeServeWebError.launchFailed(error.localizedDescription)
        }
        // The first of the URL line, the output ending, the startup deadline and cancellation
        // resumes the wait once (no task group waits for a loser).
        let outcome = FirstOutcome<Result<URL, VSCodeServeWebError>>()
        drain(fileDescriptor: pipe.fileHandleForReading.fileDescriptor, into: outcome)
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
