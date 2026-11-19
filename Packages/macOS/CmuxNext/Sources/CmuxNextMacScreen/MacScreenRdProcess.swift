import CmuxNextCompat
import CmuxNextComputerUse
import CmuxNextRemoteView
import Foundation
import os

/// One line of `cmux rd serve|connect`, as the shared Rust reader types it.
typealias MacScreenRdMessage = RemoteRdLineReader.Line

extension MacScreenRdMessage {
    /// The fields this line holds, by wire name (`key`, `candidate`, `candidates_done`, ...), for
    /// the log: which stage a session reached, never a key or an address. `unknown` for a line
    /// with none (a newer cmux's).
    nonisolated var kinds: String {
        let fields: [(Bool, String)] = [
            (displays != nil, "displays"), (current != nil, "current"), (key != nil, "key"),
            (candidate != nil, "candidate"), (candidatesDone == true, "candidates_done"),
            (connected == true, "connected"), (listening == true, "listening"), (path != nil, "path"),
            (error != nil, "error"), (ended != nil, "ended"),
        ]
        let names = fields.filter(\.0).map(\.1)
        return names.isEmpty ? "unknown" : names.joined(separator: " ")
    }
}

/// Reads one process's stdout into typed lines (the Rust reader, `RemoteRdLineReader`). The pipe's
/// readabilityHandler is its only caller; the lock keeps the reader, which is not `Sendable`, to one
/// thread at a time.
private nonisolated final class MacScreenRdLineSink: Sendable {
    private let reader: Mutex<RemoteRdLineReader>

    init(reader: consuming sending RemoteRdLineReader) {
        self.reader = Mutex(reader)
    }

    func push(_ data: Data) -> [MacScreenRdMessage] {
        reader.withLock { $0.push(data) }
    }
}

/// One `cmux rd serve|connect` process of a Mac Screen session (plans/cmux-next/remote-desktop-mac-host.md
/// section 7): the cmux.rd/1 host or the viewer's link bridge. The host (`serve`) runs in the Screen
/// Sharing helper (``MacScreenHelper``, plans/cmux-next/screen-sharing-helper.md), so macOS checks its
/// own Screen Recording and Accessibility grants, never this app's; a build without the helper runs
/// `cmux rd serve` from the bundled cmux, as before. The viewer's bridge needs no grant and runs the
/// bundled cmux. The app talks
/// to it in JSON lines. Stdout lines arrive on `lines` (read on Foundation's pipe queue, never the main
/// actor); `send` writes one line to stdin on a serial queue, so a full pipe never blocks the caller.
/// Closing stdin, or this app ending, ends the process (it reads end of file and stops its session).
nonisolated final class MacScreenRdProcess: Sendable {
    enum Role: String { case serve, connect }

    let lines: AsyncStream<MacScreenRdMessage>
    private let continuation: AsyncStream<MacScreenRdMessage>.Continuation
    private let state = Mutex(State())
    // Candidates and stop: a session start waits for them, no frame does.
    private let writes = DispatchQueue(label: "com.cmuxterm.mac-screen.rd-stdin", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mac-screen-rd")

    private struct State {
        var process: Process?
        /// The Screen Sharing helper's pid, while it serves (``SignedHelperLaunch`` reaps it).
        var helperPID: pid_t?
        var stdin: FileHandle?
        /// A spawned helper's stdout and stderr pipes, kept for this object's life. A `Process`
        /// keeps its own pipes; a spawned helper has nothing else holding them, and a released
        /// `Pipe` closes its read end under its readabilityHandler: the helper's lines then went
        /// nowhere and no end of file came, so the session never sent its answer (cmuxterm-hq#13721).
        var pipes: [Pipe] = []
        var stderrTail = Data()
    }

    init() {
        (lines, continuation) = AsyncStream.makeStream(of: MacScreenRdMessage.self, bufferingPolicy: .bufferingNewest(512))
    }

    /// The bundled cmux (`Contents/Resources/bin/cmux`), or `CMUX_NEXT_RD_BIN` in development.
    static var binary: URL? {
        if let path = ProcessInfo.processInfo.environment["CMUX_NEXT_RD_BIN"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return Bundle.main.resourceURL?.appendingPathComponent("bin/cmux")
    }

    /// Starts the host: `serve` in the Screen Sharing helper when this build carries one, else
    /// `cmux rd serve`. Throws when it will not launch. Off the caller's actor: staging the
    /// helper's copy reads and may copy files.
    @concurrent func startServe() async throws {
        guard let helper = MacScreenHelper.bundled() else { return try start(.serve) }
        // Never the bundled cmux once the helper is bundled: macOS would then check this app.
        guard let executable = await helper.executable() else { throw CocoaError(.fileReadNoPermission) }
        let pid = try startSpawned { stdin, stdout, stderr in
            try MacScreenHelper.spawn(executable, [Role.serve.rawValue], stdin: stdin, stdout: stdout, stderr: stderr)
        }
        logger.info("cmux rd: serving from the Screen Sharing helper (pid \(pid, privacy: .public))")
    }

    /// Starts a process `spawn` launches on these stdin, stdout and stderr pipes (the Screen
    /// Sharing helper; tests pass a shell) and reads it like ``start(_:)``. The pipes stay with
    /// this object, so its readers outlive the caller's scope.
    func startSpawned(_ spawn: (_ stdin: Pipe, _ stdout: Pipe, _ stderr: Pipe) throws -> pid_t) throws -> pid_t {
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        try follow(stdout: stdout, stderr: stderr)
        let pid: pid_t
        do { pid = try spawn(stdin, stdout, stderr) } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        SignedHelperLaunch.reap(pid)
        state.withLock { state in
            state.helperPID = pid
            state.stdin = stdin.fileHandleForWriting
            state.pipes = [stdout, stderr]
        }
        return pid
    }

    /// Starts `cmux rd <role>` from the bundled cmux. Throws when the binary is missing or will not launch.
    func start(_ role: Role) throws {
        // A missing or unlaunchable binary throws from run() below (no disk check on the caller's thread).
        guard let binary = Self.binary else { throw CocoaError(.fileNoSuchFile) }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["rd", role.rawValue]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try follow(stdout: stdout, stderr: stderr)
        let continuation = continuation
        process.terminationHandler = { _ in continuation.finish() }
        try process.run()
        state.withLock { state in
            state.process = process
            state.stdin = stdin.fileHandleForWriting
        }
    }

    /// Reads the process's stdout as typed lines (``lines``, finished at its end of file) and keeps
    /// its last stderr bytes.
    private func follow(stdout: Pipe, stderr: Pipe) throws {
        let continuation = continuation
        // The Rust line reader (cmux_rd_line_reader_*): one per process, used only on the pipe's queue.
        guard let reader = RemoteRdLineReader() else { throw CocoaError(.fileReadUnknown) }
        let lines = MacScreenRdLineSink(reader: reader)
        let logger = logger
        stdout.fileHandleForReading.readabilityHandler = { handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            let data = handle.blockingAvailableData()
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                logger.info("cmux rd: stdout ended")
                continuation.finish()
                return
            }
            // A line this app does not know (a newer cmux's) reads as an empty line; its fields are nil.
            for line in lines.push(data) {
                continuation.yield(line)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            let data = handle.blockingAvailableData()
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                logger.info("cmux rd: \(text, privacy: .public)")
            }
            self?.state.withLock { state in
                state.stderrTail.append(data)
                if state.stderrTail.count > 4096 { state.stderrTail.removeFirst(state.stderrTail.count - 4096) }
            }
        }
    }

    /// Writes one JSON line to the process (dropped once it ended).
    func send(_ value: some Encodable) {
        guard var line = try? JSONEncoder().encode(value) else { return }
        line.append(UInt8(ascii: "\n"))
        let handle = state.withLock { $0.stdin }
        guard let handle else { return }
        writes.async { try? handle.write(contentsOf: line) }
    }

    /// Whether `start` or `startServe` launched the process.
    var started: Bool { state.withLock { $0.process != nil || $0.helperPID != nil } }

    /// The last stderr bytes, for an error message.
    var stderrTail: String { state.withLock { String(data: $0.stderrTail, encoding: .utf8) ?? "" } }

    /// Ends the process: `stop`, then stdin closes (the process stops on end of file).
    func stop() {
        send(["stop": true])
        let handle = state.withLock { state -> FileHandle? in
            defer { state.stdin = nil }
            return state.stdin
        }
        writes.async { try? handle?.close() }
    }
}
