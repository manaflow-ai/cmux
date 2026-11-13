import CmuxNextCompat
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
        // Not `bytes`: Foundation reads every `bytes` reader in the app one at a time, and this
        // one waits on a quiet pipe for as long as the server lives (``FileHandle/readyChunks()``).
        let reader = pipe.fileHandleForReading
        let (chunks, stopReading) = reader.readyChunks()
        process.terminationHandler = { _ in
            // The server is gone: the reading stops and our read end closes, also when a process
            // it left behind still holds the pipe open.
            stopReading()
            try? reader.close()
        }
        do {
            try process.run()
        } catch {
            stopReading()
            throw VSCodeServeWebError.launchFailed(error.localizedDescription)
        }
        // The first of the URL line, the output ending, the startup deadline and cancellation
        // resumes the wait once (no task group waits for a loser).
        let outcome = FirstOutcome<Result<URL, VSCodeServeWebError>>()
        drain(chunks, into: outcome)
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

    /// Reads the server's output until it ends (end of file, or the server's exit): the first Web
    /// UI URL it prints resolves `outcome`, and the end of the output before one does resolves it
    /// as exited.
    private func drain(_ chunks: AsyncStream<Data>, into outcome: FirstOutcome<Result<URL, VSCodeServeWebError>>) {
        // task-owner: drains the server's output for the life of the process; it ends when the server exits.
        Task.detached {
            var pending = Data()
            var found = false
            // After the URL the chunks are still read, and dropped.
            for await chunk in chunks where !found {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    guard let url = URL(vscodeServeWebOutput: line) else { continue }
                    found = true
                    pending = Data()
                    outcome.resolve(.success(url))
                    break
                }
            }
            // A last line with no newline (the output ended in it).
            if !found, let url = URL(vscodeServeWebOutput: String(decoding: pending, as: UTF8.self)) {
                outcome.resolve(.success(url))
            }
            outcome.resolve(.failure(.exitedBeforeReady))
        }
    }
}
