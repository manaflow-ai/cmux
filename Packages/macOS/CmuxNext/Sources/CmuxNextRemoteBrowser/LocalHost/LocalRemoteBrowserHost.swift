public import CmuxNextRemoteView
public import Foundation
import Security

#if DEBUG
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
    public static func arguments(pageURL: URL?) -> [String] {
        ["--serve", "--listen", "127.0.0.1:0", "--lifeline"] + (pageURL.map { ["--url", $0.absoluteString] } ?? [])
    }

    /// How long a host may take to listen (a cold CEF start on a loaded Mac
    /// takes seconds, not minutes).
    public static let defaultStartTimeout: Duration = .seconds(60)

    /// Launches `executable` and returns once it listens. `workRoot` holds
    /// the per-host work directory (the CEF cache) and the host log. A host
    /// that does not listen within `timeout` (measured on `clock`) is
    /// stopped and `start` throws `Failure.timedOut`.
    public static func start(
        executable: URL, pageURL: URL?, workRoot: URL = FileManager.default.temporaryDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: Duration = LocalRemoteBrowserHost.defaultStartTimeout, clock: any Clock<Duration> = ContinuousClock(),
        secret: String? = nil
    ) async throws -> LocalRemoteBrowserHost {
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
            try process.run()
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
        // The start deadline: when it fires first, stopping the host ends its
        // stdout, which ends the read below. Cancelled once the host listens.
        let deadline = StartDeadline()
        let deadlineTask = Task {
            do {
                // wakeup-allow: one-shot bounded start deadline on the injected clock, cancelled when the host listens or exits.
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            deadline.fired = true
            try? input.fileHandleForWriting.close()
            process.terminate()
        }
        defer { deadlineTask.cancel() }
        var listening: RemoteBrowserHostListening?
        do {
            // Ends at the first listening line, or at end of file (the host exited).
            for try await line in output.fileHandleForReading.bytes.lines {
                listening = RemoteBrowserHostListening(line: line)
                if listening != nil { break }
            }
        } catch {
            listening = nil
        }
        deadlineTask.cancel()
        guard let listening, !deadline.fired else {
            try? input.fileHandleForWriting.close()
            if deadline.fired {
                throw Failure.timedOut(seconds: Int(timeout.components.seconds), log: log)
            }
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

/// Whether a host's start deadline fired (main actor).
@MainActor
private final class StartDeadline {
    var fired = false
}

#endif
