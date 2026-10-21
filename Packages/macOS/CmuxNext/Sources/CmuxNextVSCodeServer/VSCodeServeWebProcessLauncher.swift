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
        let urls = drain(fileDescriptor: pipe.fileHandleForReading.fileDescriptor)
        let timeout = startupTimeout
        do {
            let url = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: URL?.self) { group in
                    group.addTask {
                        for await url in urls { return url }
                        return nil
                    }
                    group.addTask {
                        // The startup deadline itself; cancelled as soon as the URL arrives.
                        try await Task.sleep(for: timeout)
                        throw VSCodeServeWebError.startupTimedOut
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next(), let url = first else {
                        throw VSCodeServeWebError.exitedBeforeReady
                    }
                    return url
                }
            } onCancel: {
                handle.terminate()
            }
            try Task.checkCancellation()
            return VSCodeServeWebStarted(handle: handle, url: url)
        } catch {
            handle.terminate()
            throw error
        }
    }

    /// Reads the server's output until it ends, yielding the first Web UI URL it prints.
    private func drain(fileDescriptor: Int32) -> AsyncStream<URL> {
        let (urls, continuation) = AsyncStream.makeStream(of: URL.self)
        Task.detached {
            let reader = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
            var found = false
            do {
                for try await line in reader.bytes.lines where !found {
                    if let url = URL(vscodeServeWebOutput: line) {
                        found = true
                        continuation.yield(url)
                    }
                }
            } catch {}
            continuation.finish()
        }
        return urls
    }
}
