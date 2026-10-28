public import CmuxNextRemoteView
public import CmuxNextWakeups
public import Foundation
import Security

/// A remote browser host this app starts on loopback for one remote tab
/// (remote-tab-r2.md, local host): `cmux-remote-browser-host --serve --listen
/// 127.0.0.1:0 --lifeline`. The host binds a free port and writes one
/// `{"listening":"127.0.0.1:PORT"}` line to stdout (the host's launch.rs);
/// `start` returns once that line arrives, or throws when the host exits
/// first. The host's stdin is the lifeline: `stop()` closes it and the host
/// quits. If this app quits or crashes, the kernel closes it the same way, so
/// no host outlives the app and nothing polls or scans processes.
///
/// One host serves one tab (its listener takes one viewer at a time), so each
/// local remote tab gets its own host. The CEF cache and the host log live in
/// a fresh work directory that is removed when the host exits; the host's
/// stderr log stays next to it (`logURL`) for diagnosis.
@MainActor
public final class LocalRemoteBrowserHost {
    /// Why a host did not start.
    public enum Failure: Error, Equatable {
        /// The executable could not be launched.
        case launch(String)
        /// The host exited (or closed stdout) before it listened; `log` is
        /// its stderr log.
        case exitedBeforeListening(log: URL)
        /// The host did not listen within `seconds`; it was stopped.
        case timedOut(seconds: Int, log: URL)
    }

    /// Where the host listens (always 127.0.0.1).
    public let endpoint: RemoteRdLoopbackEndpoint
    /// The per-launch secret (64 hex characters): the host serves only a
    /// viewer whose rd hello carries it as its session token. It reaches the
    /// host as the first line of the lifeline (stdin), never the command line
    /// or the environment, which other local processes can read.
    public let secret: String
    /// The host's process id.
    public let processIdentifier: Int32
    /// The host's stderr log (kept after exit, in the temporary directory).
    public let logURL: URL
    private let process: Process
    private let lifeline: FileHandle
    /// Kept open so a later stdout write never fails with a closed pipe.
    private let output: Pipe
    private let exits: AsyncStream<Int32>
    public private(set) var isStopped = false

    /// The argument list of `--serve` for `pageURL` (the first page).
    /// `--use-mock-keychain` reaches Chromium through argv, so a host binary built without
    /// that switch in rb_shim.mm never waits on the login Keychain and http(s) pages load.
    public static func arguments(pageURL: URL?) -> [String] {
        ["--serve", "--listen", "127.0.0.1:0", "--lifeline", "--use-mock-keychain"]
            + (pageURL.map { ["--url", $0.absoluteString] } ?? [])
    }

    /// How long a host may take to listen (a cold CEF start on a loaded Mac
    /// takes seconds, not minutes).
    public static let defaultStartTimeout: Duration = .seconds(60)

    /// The host's launcher: the person waits for this tab, so the spawn runs at userBlocking (Chromium's
    /// launcher task runner is USER_BLOCKING, content/browser/child_process_launcher_helper.cc). The host
    /// itself runs at userVisible for its whole life, its priority set apart from the spawn's as
    /// `ChildProcessLauncherHelper::SetProcessPriority` does, so a CEF host never competes with the work a
    /// frame waits for.
    public static func defaultLauncher() -> ProcessLauncher {
        ProcessLauncher(label: "com.cmuxterm.next.remote-browser-host", priority: .userBlocking, childPriority: .userVisible)
    }

    /// Launches `executable` and returns once it listens. `workRoot` holds
    /// the per-host work directory (the CEF cache) and the host log. A host
    /// that does not listen within `timeout` (measured on `clock`) is
    /// stopped and `start` throws `Failure.timedOut`. `launcher` spawns it off the caller's thread (a
    /// spawn takes hundreds of ms under memory pressure); nil is ``defaultLauncher()``.
    public static func start(
        executable: URL, pageURL: URL?, workRoot: URL = FileManager.default.temporaryDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: Duration = LocalRemoteBrowserHost.defaultStartTimeout, clock: any Clock<Duration> = ContinuousClock(),
        secret: String? = nil, launcher: ProcessLauncher? = nil
    ) async throws -> LocalRemoteBrowserHost {
        let launcher = launcher ?? defaultLauncher()
        let name = "cmux-rb-host-\(UUID().uuidString)"
        let work = workRoot.appending(path: name, directoryHint: .isDirectory)
        let cache = work.appending(path: "cache", directoryHint: .isDirectory)
        let log = workRoot.appending(path: "\(name).log")
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        } catch {
            throw Failure.launch(String(describing: error))
        }
        guard let secret = secret ?? Self.makeSecret() else {
            throw Failure.launch("no random bytes for the session secret")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(pageURL: pageURL)
        var childEnvironment = environment
        childEnvironment["CMUX_RB_CACHE_DIR"] = cache.path
        process.environment = childEnvironment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        let errorLog = try? FileHandle(forWritingTo: log)
        process.standardError = errorLog ?? FileHandle.nullDevice
        let (exits, exited) = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { @Sendable finished in
            // Runs on a Foundation queue, never the main thread.
            try? FileManager.default.removeItem(at: work)
            exited.yield(finished.terminationStatus)
            exited.finish()
        }
        do {
            try await launcher.launched(process)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw Failure.launch(String(describing: error))
        }
        // The child holds its own ends now; closing ours makes the host's
        // stdin end only when `lifeline` closes and stdout end at host exit.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errorLog?.close()
        try? input.fileHandleForWriting.write(contentsOf: Data((secret + "\n").utf8))
        // The start deadline is a Deadline race with the read of the host's listening line: when it wins, the host is
        // stopped (its lifeline closed and SIGTERM). The read ends at the first listening line, or at end of file (the
        // host exited).
        let lines = output.fileHandleForReading
        let lifelineEnd = input.fileHandleForWriting
        let listening: RemoteBrowserHostListening?
        do {
            listening = try await Deadline(timeout, clock: clock).run("remote-browser-host.start", onTimeout: {
                try? lifelineEnd.close()
                process.terminate()
            }) { await Self.firstListening(lines) }
        } catch is Deadline.Exceeded {
            throw Failure.timedOut(seconds: Int(timeout.components.seconds), log: log)
        } catch {
            listening = nil
        }
        guard let listening else {
            try? input.fileHandleForWriting.close()
            throw Failure.exitedBeforeListening(log: log)
        }
        return LocalRemoteBrowserHost(endpoint: listening.endpoint, secret: secret, process: process, lifeline: input.fileHandleForWriting,
                                      output: output, exits: exits, logURL: log)
    }

    private init(endpoint: RemoteRdLoopbackEndpoint, secret: String, process: Process, lifeline: FileHandle, output: Pipe,
                 exits: AsyncStream<Int32>, logURL: URL) {
        self.endpoint = endpoint
        self.secret = secret
        self.process = process
        processIdentifier = process.processIdentifier
        self.lifeline = lifeline
        self.output = output
        self.exits = exits
        self.logURL = logURL
    }

    /// The host's first listening line on `lines` (its stdout), or nil at end of file. Off main: it reads a pipe.
    @concurrent private nonisolated static func firstListening(_ lines: FileHandle) async -> RemoteBrowserHostListening? {
        do {
            for try await line in lines.bytes.lines {
                if let listening = RemoteBrowserHostListening(line: line) { return listening }
            }
        } catch {
            return nil
        }
        return nil
    }

    /// 32 bytes from `SecRandomCopyBytes` as 64 lowercase hex characters
    /// (the rd session token format); nil when the generator fails, and then
    /// no host starts.
    public static func makeSecret() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Closes the lifeline; the host quits on its own (idempotent).
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        try? lifeline.close()
    }

    /// The host's exit status once it exited (nil when it was already read).
    public func exitStatus() async -> Int32? {
        for await status in exits { return status }
        return nil
    }
}
