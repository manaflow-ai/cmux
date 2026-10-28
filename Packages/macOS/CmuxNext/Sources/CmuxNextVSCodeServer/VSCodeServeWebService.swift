import CmuxNextCompat
public import Foundation

/// The app's one inline VS Code server: `serve-web` on 127.0.0.1, started on first use.
///
/// Every caller shares the running server, and callers that arrive while it starts wait for the
/// same launch. ``stop()`` ends it (a caller still waiting gets ``VSCodeServeWebError/stopped``) and
/// ``restart(vscode:)`` replaces it. Each launch gets a fresh connection token in a private (0600)
/// file in `tokenDirectory`, removed when its server ends.
///
/// ```swift
/// let service = VSCodeServeWebService(
///     planner: VSCodeServeWebLaunchPlanner(homeDirectory: home, environment: environment),
///     launcher: VSCodeServeWebProcessLauncher(), tokenDirectory: FileManager.default.temporaryDirectory)
/// let url = try await service.url(vscode: vscodeApp, openingFolder: "/Users/me/project")
/// ```
///
/// Tests pass a fake ``VSCodeServeWebLaunching`` and a temporary `tokenDirectory`.
public actor VSCodeServeWebService {
    private struct Server {
        let generation: UInt64
        let started: VSCodeServeWebStarted
        let tokenFile: URL
    }

    private struct Launch {
        let generation: UInt64
        let task: Task<VSCodeServeWebStarted, any Error>
        let tokenFile: URL
    }

    private let planner: VSCodeServeWebLaunchPlanner
    private let launcher: any VSCodeServeWebLaunching
    private let tokenDirectory: URL
    private let makeToken: @Sendable () -> String
    private var server: Server?
    private var launch: Launch?
    private var generation: UInt64 = 0
    // The running process for `terminateForAppExit()`, which the app calls synchronously while it
    // quits and cannot await the actor. A one-slot mirror set and cleared with `server`.
    private nonisolated let exitSlot = Mutex<(any VSCodeServeWebProcessHandle)?>(nil)

    /// Creates the service. It starts nothing until the first request.
    /// - Parameters:
    ///   - planner: Picks the server binary of a VS Code install.
    ///   - launcher: Starts server processes.
    ///   - tokenDirectory: Where connection token files are written (the temporary directory).
    ///   - makeToken: A new random connection token. Defaults to a UUID without dashes.
    public init(planner: VSCodeServeWebLaunchPlanner, launcher: any VSCodeServeWebLaunching, tokenDirectory: URL,
                makeToken: @escaping @Sendable () -> String = { UUID().uuidString.replacingOccurrences(of: "-", with: "") }) {
        self.planner = planner
        self.launcher = launcher
        self.tokenDirectory = tokenDirectory
        self.makeToken = makeToken
    }

    /// Whether a server is running.
    public var isServing: Bool {
        server?.started.handle.isRunning == true
    }

    /// The running server's Web UI URL, starting the server for `vscode` first when none runs.
    /// - Parameter vscode: The VS Code app bundle.
    /// - Throws: ``VSCodeServeWebError``.
    public func url(vscode: URL) async throws -> URL {
        if let server {
            if server.started.handle.isRunning { return server.started.url }
            end(server)
        }
        let current: Launch
        if let launch {
            current = launch
        } else {
            current = try begin(vscode: vscode)
        }
        do {
            let started = try await current.task.value
            guard generation == current.generation else {
                started.handle.terminate()
                throw VSCodeServeWebError.stopped
            }
            if launch?.generation == current.generation {
                launch = nil
                server = Server(generation: current.generation, started: started, tokenFile: current.tokenFile)
                exitSlot.withLock { $0 = started.handle }
            }
            return started.url
        } catch {
            if launch?.generation == current.generation {
                launch = nil
                removeTokenFile(current.tokenFile)
            }
            if generation != current.generation { throw VSCodeServeWebError.stopped }
            throw error
        }
    }

    /// The server's URL opening the folder at `path`.
    /// - Parameters:
    ///   - vscode: The VS Code app bundle.
    ///   - path: The absolute folder path.
    /// - Throws: ``VSCodeServeWebError``.
    public func url(vscode: URL, openingFolder path: String) async throws -> URL {
        let base = try await url(vscode: vscode)
        guard let url = base.vscodeServeWebURL(openingFolder: path) else { throw VSCodeServeWebError.exitedBeforeReady }
        return url
    }

    /// Stops the server, or a launch in progress. Nothing to stop is not an error.
    public func stop() {
        generation &+= 1
        if let launch {
            launch.task.cancel()
            removeTokenFile(launch.tokenFile)
            self.launch = nil
        }
        if let server { end(server) }
    }

    /// Stops the server and starts a new one for `vscode`.
    /// - Parameter vscode: The VS Code app bundle.
    /// - Returns: The new server's Web UI URL.
    /// - Throws: ``VSCodeServeWebError``.
    public func restart(vscode: URL) async throws -> URL {
        stop()
        return try await url(vscode: vscode)
    }

    /// Ends the running server at once, for the app's `applicationWillTerminate`.
    public nonisolated func terminateForAppExit() {
        // Taken out first: the signal is sent with the lock free.
        let handle = exitSlot.withLock { slot in
            defer { slot = nil }
            return slot
        }
        handle?.terminate()
    }

    private func begin(vscode: URL) throws -> Launch {
        generation &+= 1
        let tokenFile = try writeTokenFile()
        guard let plan = planner.launch(vscode: vscode, connectionTokenFile: tokenFile) else {
            removeTokenFile(tokenFile)
            throw VSCodeServeWebError.serverMissing
        }
        let launcher = launcher
        let started = Launch(generation: generation, task: Task { try await launcher.start(plan) }, tokenFile: tokenFile)
        launch = started
        return started
    }

    private func end(_ ended: Server) {
        ended.started.handle.terminate()
        removeTokenFile(ended.tokenFile)
        if server?.generation == ended.generation {
            server = nil
            exitSlot.withLock { $0 = nil }
        }
    }

    private func writeTokenFile() throws -> URL {
        let url = tokenDirectory.appendingPathComponent("cmux-vscode-token-\(UUID().uuidString)", isDirectory: false)
        // Created 0600 and exclusively in one call, so the token is never readable by others.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw VSCodeServeWebError.tokenFileFailed }
        defer { close(descriptor) }
        let token = Array(makeToken().utf8)
        let written = token.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == token.count else {
            removeTokenFile(url)
            throw VSCodeServeWebError.tokenFileFailed
        }
        return url
    }

    private func removeTokenFile(_ url: URL) {
        try? FileManager().removeItem(at: url)
    }
}
