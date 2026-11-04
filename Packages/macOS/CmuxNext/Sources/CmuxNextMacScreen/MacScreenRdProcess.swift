import CmuxNextCompat
import Foundation
import os

/// One line from `cmux rd serve|connect` (src/serve.rs and src/connect.rs list them).
nonisolated struct MacScreenRdMessage: Decodable, Sendable, Equatable {
    struct Path: Decodable, Sendable, Equatable {
        var kind: String?
        var rttMs: Double?
        enum CodingKeys: String, CodingKey { case kind, rttMs = "rtt_ms" }
    }

    var key: String?
    var candidate: String?
    var candidatesDone: Bool?
    var connected: Bool?
    var listening: Bool?
    var ended: String?
    var path: Path?
    var displays: [[UInt32]]?
    var current: Int?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case key, candidate, connected, listening, ended, path, displays, current, error
        case candidatesDone = "candidates_done"
    }
}

/// Splits stdout bytes into lines (one reader at a time: Foundation's pipe queue).
private nonisolated final class MacScreenRdLines: Sendable {
    private let pending = Mutex(Data())

    func append(_ data: Data) -> [Data] {
        pending.withLock { pending in
            pending.append(data)
            var lines: [Data] = []
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(Data(pending[pending.startIndex ..< newline]))
                pending.removeSubrange(pending.startIndex ... newline)
            }
            return lines
        }
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
        guard let binary = Self.binary, FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["rd", role.rawValue]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let continuation = continuation
        let splitter = MacScreenRdLines()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in splitter.append(data) {
                // A line this app does not know (a newer cmux) decodes to an empty message and is ignored.
                if let message = try? JSONDecoder().decode(MacScreenRdMessage.self, from: line) {
                    continuation.yield(message)
                }
            }
        }
        let logger = logger
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            let data = handle.availableData
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
