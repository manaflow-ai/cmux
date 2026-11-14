import Darwin
package import Foundation
import CmuxNextCompat

/// A cmux-tui helper process (`wg hub`, `remote connect`) whose stdout is a
/// stream of JSON lines. Reading happens on Foundation's pipe threads, never
/// the main actor. Stdout lines are bounded (drop-oldest past 256 pending);
/// stderr keeps a 4 KB tail for error messages and, with `stderrLog`, goes
/// to that file too (owner only, emptied at each launch, at most
/// ``stderrLogLimit`` bytes), the way `cmux link ensure` keeps its link's
/// output in `link.log`. The child runs with `--exit-with-parent`, so a
/// crash of this app ends it too.
package final class ChildProcess: Sendable {
    private struct State {
        var process: Process?
        var stderrTail = Data()
        var stderrLog: FileHandle?
        var stderrLogged = 0
        var exitStatus: Int32?
        var exitWaiters: [CheckedContinuation<Int32, Never>] = []
        /// The write end of a held stdin (``startHoldingInput()``): closing it tells the child to exit.
        var input: FileHandle?
    }

    /// The most stderr one launch writes to `stderrLog`.
    package static let stderrLogLimit = 4 * 1024 * 1024

    package let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    /// Stderr as lines too (a `carrier serve` writes its ready line there).
    package let stderrLines: AsyncStream<String>
    private let stderrContinuation: AsyncStream<String>.Continuation
    private let state = Mutex(State())
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let input: Data?
    private let stderrLog: URL?

    /// A bounded secret is fed after launch (``PipeFeed``); inherited Native sockets use start(inheritedInput:).
    /// `stderrLog` also keeps the child's stderr in that file (never its stdin or stdout).
    package init(executable: URL, arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
                 input: Data? = nil, stderrLog: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.input = input
        self.stderrLog = stderrLog
        (lines, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(256))
        (stderrLines, stderrContinuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(256))
    }

    /// Starts the child with a stdin this process holds open until ``closeInput()`` (or its own exit):
    /// a child that exits when its stdin closes then lives exactly as long as this owner wants.
    package func startHoldingInput() throws {
        let stdin = Pipe()
        // A line to a child that exited fails instead of raising SIGPIPE, and a full pipe drops it, never blocks.
        let writer = stdin.fileHandleForWriting.fileDescriptor
        _ = fcntl(writer, F_SETNOSIGPIPE, 1)
        _ = fcntl(writer, F_SETFL, fcntl(writer, F_GETFL) | O_NONBLOCK)
        state.withLock { $0.input = stdin.fileHandleForWriting }
        try launch(standardInput: stdin.fileHandleForReading)
        try? stdin.fileHandleForReading.close()
    }

    /// Writes `line` and a newline to the held stdin (``startHoldingInput()``); false when it is closed or did not take it all.
    @discardableResult
    package func writeInput(line: String) -> Bool {
        let bytes = Array((line + "\n").utf8)
        return state.withLock { state in
            guard let input = state.input else { return false }
            // concurrency-allow: the held stdin is O_NONBLOCK (startHoldingInput): a full pipe fails the write, never waits
            return bytes.withUnsafeBytes { Darwin.write(input.fileDescriptor, $0.baseAddress, $0.count) } == bytes.count
        }
    }

    /// Closes the held stdin (``startHoldingInput()``); the child exits on its own.
    package func closeInput() {
        let input = state.withLock { state -> FileHandle? in defer { state.input = nil }; return state.input }
        try? input?.close()
    }

    package func start() throws {
        let stdin = input.map { _ in Pipe() }
        if let input { guard input.count <= 16 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) } }
        guard let stdin, let input else {
            try launch(standardInput: FileHandle.nullDevice)
            return
        }
        // Close-on-exec on both ends: no other child of this app inherits a copy of the secret's pipe.
        _ = fcntl(stdin.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        // The secret goes in after launch on the feed's own queue, never this caller's thread
        // (main-actor code): a pipe write can wait however few the bytes (ProcessRunner's
        // two-token write before launch held the NIGHTLY main thread 391 s, 2026-11-09).
        let feed = PipeFeed(stdin.fileHandleForWriting)
        defer { try? stdin.fileHandleForReading.close() }
        do {
            try launch(standardInput: stdin.fileHandleForReading)
        } catch {
            feed.close()
            throw error
        }
        // The child holds its own read end now: drop ours first, so a child that exits without
        // reading fails the write (EPIPE) instead of leaving it waiting.
        try? stdin.fileHandleForReading.close()
        feed.write(input)
        feed.close()
    }

    /// A private socket inherited as stdin, for the owned Native link only.
    package func start(inheritedInput: FileHandle) throws {
        try launch(standardInput: inheritedInput)
    }

    private func launch(standardInput: FileHandle) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = standardInput
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let (splitter, errSplitter) = (LineSplitter(), LineSplitter())
        let (continuation, stderrContinuation) = (continuation, stderrContinuation)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            switch handle.readReady() {
            case .bytes(let data): for line in splitter.append(data) { continuation.yield(line) }
            case .retry: return
            case .end: handle.readabilityHandler = nil; continuation.finish()
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            switch handle.readReady() {
            case .bytes(let data):
                for line in errSplitter.append(data) { stderrContinuation.yield(line) }
                self?.state.withLock { state in
                state.stderrTail.append(data)
                if state.stderrTail.count > 4096 { state.stderrTail.removeFirst(state.stderrTail.count - 4096) }
                if let log = state.stderrLog, state.stderrLogged < Self.stderrLogLimit {
                    let chunk = data.prefix(Self.stderrLogLimit - state.stderrLogged)
                    do { try log.write(contentsOf: chunk); state.stderrLogged += chunk.count }
                    catch { try? log.close(); state.stderrLog = nil }
                }
            }
            case .retry: return
            case .end:
                handle.readabilityHandler = nil
                stderrContinuation.finish()
                self?.state.withLock { state in try? state.stderrLog?.close(); state.stderrLog = nil }
            }
        }
        let log = stderrLog.flatMap(Self.openLog)
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let waiters = self?.state.withLock { state -> [CheckedContinuation<Int32, Never>] in
                state.exitStatus = status
                try? state.input?.close()
                state.input = nil
                defer { state.exitWaiters.removeAll() }
                return state.exitWaiters
            } ?? []
            for waiter in waiters { waiter.resume(returning: status) }
        }
        state.withLock { state in
            try? state.stderrLog?.close()
            state.process = process; state.stderrLog = log; state.stderrLogged = 0
        }
        do {
            try process.run()
        } catch {
            if process.isRunning { process.terminate() }
            // It never ran: no termination handler comes, so record the exit here (status 127, as a shell's
            // "could not run"), end both line streams and resume every exit waiter instead of leaving them forever.
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            stderrContinuation.finish()
            let waiters = state.withLock { state -> [CheckedContinuation<Int32, Never>] in
                state.exitStatus = Self.notRun
                try? state.input?.close()
                state.input = nil
                try? state.stderrLog?.close()
                state.stderrLog = nil
                defer { state.exitWaiters.removeAll() }
                return state.exitWaiters
            }
            for waiter in waiters { waiter.resume(returning: Self.notRun) }
            throw error
        }
    }

    /// The exit status recorded for a child whose `Process.run()` threw.
    package static let notRun: Int32 = 127

    /// `url` opened to append, owner only, never through a symlink (its folder made owner only when missing);
    /// nil when it cannot be. It starts empty unless a running link holds the folder's `link.lock`: a classic
    /// `cmux link serve` that is still running (it outlives the app) keeps writing this same `link.log`, and its
    /// lines are the ones that say why the Native child then could not start.
    private static func openLog(_ url: URL) -> FileHandle? {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let empty = !linkLockHeld(folder.appendingPathComponent("link.lock", isDirectory: false))
        let flags = O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC | (empty ? O_TRUNC : 0)
        let fd = Darwin.open(url.path, flags, 0o600)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// True while another process holds `lock` (the link's single-instance flock).
    private static func linkLockHeld(_ lock: URL) -> Bool {
        let fd = Darwin.open(lock.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(fd, LOCK_UN)
        return false
    }

    package var pid: Int32? { state.withLock { $0.process?.processIdentifier } }
    package var isRunning: Bool { state.withLock { $0.process != nil && $0.exitStatus == nil } }

    package var stderrText: String {
        let data = state.withLock { $0.stderrTail }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The tasks waiting in ``waitForExit()`` now.
    package var exitWaiterCount: Int { state.withLock { $0.exitWaiters.count } }

    package func waitForExit() async -> Int32 {
        await withCheckedContinuation { waiter in
            let done = state.withLock { state -> Int32? in
                if let status = state.exitStatus { return status }
                state.exitWaiters.append(waiter)
                return nil
            }
            if let done { waiter.resume(returning: done) }
        }
    }

    /// SIGTERM to this process only, not its process group: a `remote
    /// connect` link client still needs its ssh child to send the session's
    /// close frame, and then ends ssh itself (cx-bj1o). `terminate()` signals
    /// the whole group, so ssh died first and the remote daemon held the
    /// session for its resume lease.
    package func terminateProcessOnly() {
        guard let pid = state.withLock({ $0.exitStatus == nil ? $0.process?.processIdentifier : nil }), pid > 0 else { return }
        kill(pid, SIGTERM)
    }

    /// SIGTERM; the helpers exit and remove their sockets.
    package func terminate() {
        let process = state.withLock { $0.exitStatus == nil ? $0.process : nil }
        process?.terminate()
    }

    /// The first stdout (or `stderr`) line `match` accepts, within `deadline`. Throws when
    /// the process exits first (with its stderr) or the deadline passes.
    package func firstLine<T: Sendable>(within deadline: Duration, label: String, stderr: Bool = false,
                                _ match: @escaping @Sendable (String) -> T?) async throws -> T {
        let lines = stderr ? stderrLines : lines
        return try await withDeadline(deadline, label: label) { [weak self] in
            for await line in lines {
                if let value = match(line) { return value }
            }
            throw ChildProcessError.exited(label: label, stderr: self?.stderrText ?? "")
        }
    }
}

package enum ChildProcessError: Error, Sendable, CustomStringConvertible {
    case exited(label: String, stderr: String)
    case missingBinary(String)

    package var description: String {
        switch self {
        case .exited(let label, let stderr): stderr.isEmpty ? "\(label) exited" : "\(label) exited: \(stderr)"
        case .missingBinary(let path): "cmux-tui not found at \(path)"
        }
    }
}

/// Splits a byte stream into newline-terminated UTF-8 lines.
final class LineSplitter: Sendable {
    private let buffer = Mutex(Data())

    func append(_ data: Data) -> [String] {
        buffer.withLock { buffer in
            buffer.append(data)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                lines.append(String(decoding: line, as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            if buffer.count > 1 << 20 { buffer.removeAll() }
            return lines
        }
    }
}
