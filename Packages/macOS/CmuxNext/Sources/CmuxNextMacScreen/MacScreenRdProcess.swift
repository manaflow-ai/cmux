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

/// One `cmux rd serve|connect` process of a Mac Screen session (plans/cmux-next/remote-desktop-mac-host.md
/// section 7): the bundled cmux binary runs the cmux.rd/1 host or the viewer's link bridge. The app talks
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

    /// Starts `cmux rd <role>`. Throws when the binary is missing or will not launch.
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
        let continuation = continuation
        // The Rust line reader (cmux_rd_line_reader_*): one per process, used only on the pipe's queue.
        guard let reader = RemoteRdLineReader() else { throw CocoaError(.fileReadUnknown) }
        let lines = MacScreenRdLineSink(reader: reader)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            let data = handle.blockingAvailableData()
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            // A line this app does not know (a newer cmux's) reads as an empty line; its fields are nil.
            for line in lines.push(data) {
                continuation.yield(line)
            }
        }
        let logger = logger
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
        process.terminationHandler = { _ in continuation.finish() }
        try process.run()
        state.withLock { state in
            state.process = process
            state.stdin = stdin.fileHandleForWriting
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

    /// Whether `start` launched the process.
    var started: Bool { state.withLock { $0.process != nil } }

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
