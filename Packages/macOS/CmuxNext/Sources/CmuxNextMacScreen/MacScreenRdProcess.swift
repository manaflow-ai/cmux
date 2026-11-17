import CmuxNextCompat
import CmuxNextRemoteView
import Foundation
import os

/// One line of `cmux rd serve|connect`, as the shared Rust reader types it.
typealias MacScreenRdMessage = RemoteRdLineReader.Line

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

/// One cmux.rd/1 process of a Mac Screen session (plans/cmux-next/remote-desktop-mac-host.md
/// section 7): the host or the viewer's link bridge. The host (`cmux-screen-sharing serve`) is a
/// child of cmux Computer Use's Screen Sharing worker, reached through a worker channel
/// (``MacScreenCaptureWorker``, ``attach(socket:)``), so macOS checks the helper's Screen
/// Recording and Accessibility, never this app's; this app never runs a screen host itself. The
/// viewer's bridge (`cmux rd connect`) needs no grant and runs the bundled cmux. The app talks to
/// either in JSON lines. Lines arrive on `lines` (read on Foundation's queue, never the main
/// actor); `send` writes one line on a serial queue, so a full pipe never blocks the caller.
/// Closing its input ends the process (it reads end of file and stops its session); the host
/// also outlives this app when the worker keeps a connected session (headless).
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
        /// The worker channel of a host (``attach(socket:)``): both its input and its output.
        var socket: Int32?
        /// ``attach(socket:)`` ran (the host started in the worker).
        var attached = false
        var stdin: FileHandle?
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

    /// The host, through the worker channel `socket` (past the worker's answer to `session.rd`):
    /// lines written here reach the host's stdin, its stdout lines arrive on ``lines``.
    func attach(socket: Int32) {
        let handle = FileHandle(fileDescriptor: socket, closeOnDealloc: false)
        follow(stdout: handle, stderr: nil) { [weak self] in self?.closeSocket() }
        state.withLock { state in
            state.socket = socket
            state.attached = true
            state.stdin = handle
        }
        logger.info("cmux rd: serving through cmux Computer Use's Screen Sharing worker")
    }

    /// The worker channel ended: its descriptor closes once.
    private func closeSocket() {
        let socket = state.withLock { state -> Int32? in
            defer {
                state.socket = nil
                state.stdin = nil
            }
            return state.socket
        }
        if let socket { writes.async { Darwin.close(socket) } }
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
        follow(stdout: stdout.fileHandleForReading, stderr: stderr.fileHandleForReading)
        let continuation = continuation
        process.terminationHandler = { _ in continuation.finish() }
        try process.run()
        state.withLock { state in
            state.process = process
            state.stdin = stdin.fileHandleForWriting
        }
    }

    /// Reads the process's stdout as typed lines (``lines``, finished at its end of file, then
    /// `ended`) and keeps its last stderr bytes.
    private func follow(stdout: FileHandle, stderr: FileHandle?, ended: @escaping @Sendable () -> Void = {}) {
        let continuation = continuation
        // The Rust line reader (cmux_rd_line_reader_*): one per process, used only on the pipe's queue.
        guard let reader = RemoteRdLineReader() else {
            continuation.finish()
            ended()
            return
        }
        let lines = MacScreenRdLineSink(reader: reader)
        stdout.readabilityHandler = { handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            let data = handle.blockingAvailableData()
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish()
                ended()
                return
            }
            // A line this app does not know (a newer cmux's) reads as an empty line; its fields are nil.
            for line in lines.push(data) {
                continuation.yield(line)
            }
        }
        let logger = logger
        stderr?.readabilityHandler = { [weak self] handle in
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

    /// Whether `start` launched the process or ``attach(socket:)`` reached the worker's host.
    var started: Bool { state.withLock { $0.process != nil || $0.attached } }

    /// The last stderr bytes, for an error message.
    var stderrTail: String { state.withLock { String(data: $0.stderrTail, encoding: .utf8) ?? "" } }

    /// Ends the process: `stop`, then its input closes (it stops on end of file). A worker
    /// channel closes only its write side here; it closes once the worker's end of file arrives.
    func stop() {
        send(["stop": true])
        let (handle, socket) = state.withLock { state -> (FileHandle?, Int32?) in
            defer { state.stdin = nil }
            return (state.stdin, state.socket)
        }
        writes.async {
            if let socket { _ = shutdown(socket, SHUT_WR) } else { try? handle?.close() }
        }
    }
}
