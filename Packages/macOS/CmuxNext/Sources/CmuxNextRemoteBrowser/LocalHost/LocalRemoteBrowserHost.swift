public import CmuxNextRemoteView
public import Foundation

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
    }

    /// Where the host listens (always 127.0.0.1).
    public let endpoint: RemoteRdLoopbackEndpoint
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

    /// Launches `executable` and returns once it listens. `workRoot` holds
    /// the per-host work directory (the CEF cache) and the host log.
    public static func start(
        executable: URL, pageURL: URL?, workRoot: URL = FileManager.default.temporaryDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment
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
        guard let listening else {
            try? input.fileHandleForWriting.close()
            throw Failure.exitedBeforeListening(log: log)
        }
        return LocalRemoteBrowserHost(endpoint: listening.endpoint, process: process, lifeline: input.fileHandleForWriting,
                                      output: output, exits: exits, logURL: log)
    }

    private init(endpoint: RemoteRdLoopbackEndpoint, process: Process, lifeline: FileHandle, output: Pipe,
                 exits: AsyncStream<Int32>, logURL: URL) {
        self.endpoint = endpoint
        self.process = process
        processIdentifier = process.processIdentifier
        self.lifeline = lifeline
        self.output = output
        self.exits = exits
        self.logURL = logURL
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

/// The host's readiness line, `{"listening":"127.0.0.1:PORT"}`; nil for any
/// other line or a non-loopback address.
public nonisolated struct RemoteBrowserHostListening: Sendable, Equatable {
    public let endpoint: RemoteRdLoopbackEndpoint

    public init?(line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let address = object["listening"] as? String,
              address.hasPrefix("127.0.0.1:"),
              let record = RemoteBrowserTabRecord(address: address) else { return nil }
        endpoint = record.endpoint
    }
}

/// Finds the remote browser host: `CMUX_NEXT_RB_HOST` (a host `.app` or its
/// executable), else the host app this build bundles at
/// `Contents/Helpers/cmux-remote-browser-host.app`. The host must run from an
/// app bundle: CEF loads its framework and helper apps relative to it
/// (scripts/cmux-next/bundle-remote-browser-host.sh makes that layout).
public nonisolated struct LocalRemoteBrowserHostLocator: Sendable {
    public static let environmentKey = "CMUX_NEXT_RB_HOST"
    public static let bundledAppPath = "Contents/Helpers/cmux-remote-browser-host.app"
    public static let executableName = "cmux-remote-browser-host"

    public let environment: [String: String]
    public let appBundle: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, appBundle: URL = Bundle.main.bundleURL) {
        self.environment = environment
        self.appBundle = appBundle
    }

    /// The candidates in order (the override first).
    public var candidates: [URL] {
        let override = environment[Self.environmentKey].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return [override, appBundle.appending(path: Self.bundledAppPath)].compactMap { $0 }.map(Self.executable(in:))
    }

    /// The first candidate that is an executable file.
    public func executable() -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// A host `.app` names its executable; any other path is the executable.
    static func executable(in url: URL) -> URL {
        url.pathExtension == "app" ? url.appending(path: "Contents/MacOS/\(executableName)") : url
    }
}
#endif
