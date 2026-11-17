import CmuxNextCompat
import CmuxNextComputerUse
import CmuxNextRemoteView
import CmuxScreenKit
import Darwin
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
        /// The cmux Remote channel that is the host's stdio (``startRemote(_:)``), until it ends.
        var remoteSocket: Int32?
        var startedRemote = false
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

    /// Starts the host: `serve` in the Screen Sharing helper when this build carries one, else
    /// `cmux rd serve`. Throws when it will not launch. Off the caller's actor: staging the
    /// helper's copy reads and may copy files.
    @concurrent func startServe() async throws {
        guard let helper = MacScreenHelper.bundled() else { return try start(.serve) }
        // Never the bundled cmux once the helper is bundled: macOS would then check this app.
        guard let executable = await helper.executable() else { throw CocoaError(.fileReadNoPermission) }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        try follow(stdout: stdout, stderr: stderr)
        let pid = try helper.spawn(executable, [Role.serve.rawValue], stdin: stdin, stdout: stdout, stderr: stderr)
        SignedHelperLaunch.reap(pid)
        logger.info("cmux rd: serving from the Screen Sharing helper (pid \(pid, privacy: .public))")
        state.withLock { state in
            state.helperPID = pid
            state.stdin = stdin.fileHandleForWriting
        }
    }

    /// Starts the host in cmux Remote's Screen Sharing worker (docs/cmux-remote.md, "Attached
    /// capture"): `open` gives a fresh `screen-sharing` channel, which becomes the host's stdin
    /// and stdout once the worker answers `screen.rd_serve`. The host is the worker's child, so
    /// macOS checks cmux Remote's Screen Recording and Accessibility, never this app's. Throws
    /// when cmux Remote refuses or is gone. Off the caller's actor: the opening exchange blocks.
    @concurrent func startRemote(_ open: @Sendable () async throws -> Int32) async throws {
        let socket = try await open()
        do { try Self.requestRemoteServe(socket) } catch {
            Darwin.close(socket)
            throw error
        }
        state.withLock { state in
            state.remoteSocket = socket
            state.startedRemote = true
            state.stdin = FileHandle(fileDescriptor: socket, closeOnDealloc: false)
        }
        followRemote(socket)
        logger.info("cmux rd: serving from cmux Remote's Screen Sharing worker")
    }

    /// `screen.rd_serve` and its answer; the channel carries only the host's lines after it.
    private static func requestRemoteServe(_ socket: Int32) throws {
        let request: [String: Any] = ["id": 1, "method": AttachedScreenHost.rdServe, "params": [String: String]()]
        guard var line = try? JSONSerialization.data(withJSONObject: request) else { throw CocoaError(.coderInvalidValue) }
        line.append(UInt8(ascii: "\n"))
        guard RemoteSocket.writeAll(socket, line), let reply = RemoteSocket.readLine(socket),
              let answer = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else {
            throw CmuxRemoteError.refused("cmux Remote closed the screen channel")
        }
        guard answer["ok"] as? Bool == true else {
            throw CmuxRemoteError.refused((answer["error"] as? [String: Any])?["message"] as? String ?? "refused")
        }
    }

    /// Reads the remote host's lines (the channel) into ``lines``; at its end the channel closes
    /// after every queued write ran, so no write reaches a reused descriptor.
    private func followRemote(_ socket: Int32) {
        let continuation = continuation
        guard let reader = RemoteRdLineReader() else {
            continuation.finish()
            closeRemote()
            return
        }
        let lines = MacScreenRdLineSink(reader: reader)
        let handle = FileHandle(fileDescriptor: socket, closeOnDealloc: false)
        handle.readabilityHandler = { [weak self] handle in
            // concurrency-allow: readabilityHandler runs on Foundation's queue, never main; data is ready.
            let data = handle.blockingAvailableData()
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish()
                self?.closeRemote()
                return
            }
            for line in lines.push(data) {
                continuation.yield(line)
            }
        }
    }

    private func closeRemote() {
        writes.async { [weak self] in
            guard let self else { return }
            let socket = state.withLock { state -> Int32? in
                defer {
                    state.remoteSocket = nil
                    state.stdin = nil
                }
                return state.remoteSocket
            }
            if let socket { Darwin.close(socket) }
        }
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
    }

    /// Writes one JSON line to the process (dropped once it ended).
    func send(_ value: some Encodable) {
        guard var line = try? JSONEncoder().encode(value) else { return }
        line.append(UInt8(ascii: "\n"))
        guard state.withLock({ $0.stdin != nil }) else { return }
        // The handle is read when the write runs: a cmux Remote channel may have closed meanwhile.
        writes.async { [weak self] in
            guard let handle = self?.state.withLock({ $0.stdin }) else { return }
            try? handle.write(contentsOf: line)
        }
    }

    /// Whether `start`, `startServe` or `startRemote` launched the process.
    var started: Bool { state.withLock { $0.process != nil || $0.helperPID != nil || $0.startedRemote } }

    /// The last stderr bytes, for an error message (none for a host in cmux Remote: it logs them).
    var stderrTail: String { state.withLock { String(data: $0.stderrTail, encoding: .utf8) ?? "" } }

    /// Ends the process: `stop`, then stdin closes (the process stops on end of file). A host in
    /// cmux Remote reads end of file when this side of its channel shuts; the worker then ends
    /// the channel, and its end closes the descriptor (``followRemote(_:)``).
    func stop() {
        send(["stop": true])
        writes.async { [weak self] in
            guard let self else { return }
            let (handle, socket) = state.withLock { state -> (FileHandle?, Int32?) in
                defer { state.stdin = nil }
                return (state.stdin, state.remoteSocket)
            }
            if let socket {
                _ = shutdown(socket, SHUT_WR)
            } else {
                try? handle?.close()
            }
        }
    }
}
