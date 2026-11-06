public import CmuxNextWakeups
public import Foundation
import CmuxNextCompat
import CmuxNextDaemon
import Darwin

/// The bundled `cmux` binary as the app's one runner of stdin-JSON subcommands (`cmux cloud api`,
/// `cmux cloud machine-io`, `cmux carrier secrets`, ...): the logic lives in cmux-tui Rust and Swift only
/// forwards. One request goes on the child's stdin (a credential never goes in argv, which other
/// processes can read), and its stdout comes back; ``line(_:stdin:timeout:)`` answers the last line.
public struct BundledCmux: Sendable {
    /// The `cmux` binary (`Contents/Resources/bin/cmux`).
    public let binary: URL
    /// The app's blocking-work lanes: every file call of a run (the answer's temp file and its read) runs on
    /// `.files`, never on the cooperative pool (threading-model.md).
    public let work: BackgroundWork

    public init(binary: URL, work: BackgroundWork) {
        self.binary = binary
        self.work = work
    }

    /// The app's: the bundled cmux at `bundleResources/bin/cmux`, or the cmux-tui built from source that
    /// `environment`'s `CMUX_NEXT_TUI_BIN` names. It touches no file (the Cloud service makes it on the main
    /// thread at start); a build without it answers every run with ``NoAnswer``.
    public init?(bundleResources: URL?, work: BackgroundWork,
                 environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let override = environment[DaemonLauncher.binaryOverrideKey], !override.isEmpty {
            self.init(binary: URL(fileURLWithPath: override), work: work)
        } else {
            guard let resources = bundleResources else { return nil }
            self.init(binary: resources.appendingPathComponent("bin/cmux"), work: work)
        }
    }

    /// The child gave no answer. `dispatched` false: it never started (no binary, a cancel first), so
    /// nothing ran. `dispatched` true: it started and then crashed, timed out or printed nothing usable,
    /// so the operation may have run and a change must not be sent a second time.
    public struct NoAnswer: Error, Sendable { public var dispatched: Bool }

    /// The last non-empty line the child printed (``run(_:stdin:timeout:)``); no line is ``NoAnswer``
    /// (dispatched). Off the caller's actor (`@concurrent`): the app calls from main-actor handlers.
    @concurrent public func line(_ arguments: [String], stdin: Data, timeout: Duration) async throws -> Data {
        let output = try await run(arguments, stdin: stdin, timeout: timeout)
        guard let line = output.split(separator: UInt8(ascii: "\n")).last(where: { !$0.isEmpty }) else {
            throw NoAnswer(dispatched: true)
        }
        return Data(line)
    }

    /// `cmux arguments` with `stdin`: everything it printed.
    @concurrent public func run(_ arguments: [String], stdin: Data, timeout: Duration) async throws -> Data {
        try await Self.run(binary, arguments: arguments, stdin: stdin, timeout: timeout, work: work)
    }

    /// Runs the child with `stdin` written through a pipe after launch (a file write's request is
    /// larger than a pipe buffer) and its stdout in an unlinked temp file. Past `timeout` the child is
    /// killed and this throws ``NoAnswer``; so does a child that cannot start. The temp file is made and read on
    /// `work`'s files lane; a lane that refuses (quit) throws `CancellationError`, before the launch or after the exit.
    @concurrent private static func run(_ binary: URL, arguments: [String], stdin: Data, timeout: Duration,
                                        work: BackgroundWork) async throws -> Data {
        try Task.checkCancellation()
        let output = try await work.run(.userVisible, mayBlock: .files) { try TemporaryOutput() }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let input = Pipe()
        let reader = input.fileHandleForReading, writer = input.fileHandleForWriting
        // Close-on-exec: no other child this app starts inherits a copy of the request (Process dup2s
        // the read end into this child's stdin, which clears the flag there only).
        _ = fcntl(reader.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writer.fileDescriptor, F_SETFD, FD_CLOEXEC)
        // A child that exits before reading it all makes the write fail (EPIPE), never SIGPIPE the app.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input
        process.standardOutput = output.handle
        process.standardError = FileHandle.nullDevice
        // From here on only the child's lock touches the process.
        let child = Child(process)
        let status: Int32? = await withTaskCancellationHandler {
            await withTaskGroup(of: Int32?.self) { group in
                group.addTask {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
                        // Not started (cancelled first, or it could not start): nothing ran, and its exit
                        // handler is never set, so this is the one resume.
                        guard child.launch(exited: { continuation.resume(returning: $0) }) else {
                            continuation.resume(returning: nil)
                            return
                        }
                    }
                }
                group.addTask {
                    // wakeup-allow: one-shot deadline (child process timeout)
                    try? await Task.sleep(for: timeout)
                    return Int32.min
                }
                // The request goes in after launch, on its own thread (threading-model.md): the child reads it
                // while it is written, and the write blocks only that thread. It ends when the child has read it all
                // or closed its stdin (EPIPE, never SIGPIPE), which a kill at the deadline or a cancel also does.
                let feeder = Thread {
                    try? writer.write(contentsOf: stdin)
                    try? writer.close()
                }
                feeder.name = "cmux.bundled-cmux.stdin"
                feeder.start()
                defer { group.cancelAll() }
                let first = await group.next() ?? nil
                if first == Int32.min { child.kill() }
                return first == Int32.min ? nil : first
            }
        } onCancel: {
            child.kill()
        }
        try? reader.close()
        guard child.started else { throw NoAnswer(dispatched: false) }
        try Task.checkCancellation()
        guard status != nil else { throw NoAnswer(dispatched: true) }
        return try await work.run(.userVisible, mayBlock: .files) { output.contents() }
    }
}

/// One child run. `Process` is not Sendable, so the process lives inside the lock with the launch and
/// kill state: launch, setting its exit handler, and kill all happen under that one lock, and a kill
/// that comes first is remembered (as ProcessBox does), so a cancel or a deadline before launch means
/// no child ever starts. Sendable by its stored property (a ``Mutex``), not by an unchecked promise.
private final class Child: Sendable {
    private struct State {
        var process: Process
        var launched = false, killed = false
    }

    private let state: Mutex<State>

    init(_ process: sending Process) { state = Mutex(State(process: process)) }

    /// Starts the child unless a kill came first; true when it started. `exited` gets its exit status
    /// and is set only on a child that starts, so it runs at most once and never for one that did not.
    func launch(exited: @escaping @Sendable (Int32) -> Void) -> Bool {
        state.withLock { state in
            if state.killed { return false }
            state.process.terminationHandler = { exited($0.terminationStatus) }
            do {
                try state.process.run()
            } catch {
                state.process.terminationHandler = nil
                return false
            }
            state.launched = true
            return true
        }
    }

    var started: Bool { state.withLock { $0.launched } }

    /// SIGKILL to this child only, and only while it runs (never a pid that may be another's by now).
    func kill() {
        state.withLock { state in
            state.killed = true
            guard state.launched, state.process.isRunning else { return }
            let pid = state.process.processIdentifier
            if pid > 0 { _ = Darwin.kill(pid, SIGKILL) }
        }
    }
}

/// An unlinked temp file for the child's stdout: a large answer cannot fill a pipe and stall it.
private struct TemporaryOutput: Sendable {
    let handle: FileHandle

    init() throws {
        var template = Array((NSTemporaryDirectory() + "cmux-bundled.XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw BundledCmux.NoAnswer(dispatched: false) }
        template.withUnsafeBufferPointer { buffer in if let base = buffer.baseAddress { _ = unlink(base) } }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func contents() -> Data {
        // concurrency-allow: a local temp file read once after the child exited, on the BackgroundWork files lane (run)
        (try? handle.seek(toOffset: 0)).flatMap { _ in try? handle.blockingReadToEnd() } ?? Data()
    }
}
