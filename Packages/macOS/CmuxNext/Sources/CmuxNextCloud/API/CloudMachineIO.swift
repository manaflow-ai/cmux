public import Foundation
import CmuxNextCompat
import Darwin

/// A Worker machine's exec and file routes through the bundled cmux-tui (`cmux cloud machine-io`,
/// cmux-tui `cli/cloud_machine_io.rs`), which talks to the machine's provider directly with a
/// short-lived client session and falls back to the cmux API's own routes on its own. This type
/// only forwards: one JSON request on the child's stdin (the credential never goes in argv), one
/// JSON line back with the route's status, error code and body, exactly as
/// `/v1/cloud/machines/{id}/...` would have answered.
public struct CloudMachineIO: Sendable {
    /// The `cmux` binary (`Contents/Resources/bin/cmux`).
    public let binary: URL
    /// Where cmux-tui keeps its client sessions (0700; one 0600 file per machine and person).
    public let cacheDirectory: URL

    public init(binary: URL, cacheDirectory: URL) {
        self.binary = binary
        self.cacheDirectory = cacheDirectory
    }

    /// The route's answer: `status` 0 is none at all (then `code` says why: `timed_out` or `transport`).
    struct Answer: Sendable {
        var status: Int
        var code: String?
        var body: Data
        var route: String
    }

    /// The child gave no answer line. `dispatched` false: it never started (no binary, a cancel first) or
    /// said it took nothing (route `none`), so nothing ran and the caller may take the HTTP route.
    /// `dispatched` true: it started and then crashed, timed out or printed nothing usable, so the
    /// operation may have run and a change must not be sent a second time.
    struct NoAnswer: Error { var dispatched: Bool }

    func perform(_ request: [String: any Sendable], timeout: Duration) async throws -> Answer {
        var request = request
        request["cache_dir"] = cacheDirectory.path
        let input = try JSONSerialization.data(withJSONObject: request)
        let output = try await Self.run(binary, arguments: ["cloud", "machine-io"], stdin: input, timeout: timeout)
        guard let line = output.split(separator: UInt8(ascii: "\n")).last(where: { !$0.isEmpty }),
              let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let status = object["status"] as? Int, let route = object["route"] as? String else { throw NoAnswer(dispatched: true) }
        guard route == "direct" || route == "proxy" else { throw NoAnswer(dispatched: route != "none") }
        let body = object["body"].flatMap { $0 is NSNull ? nil : try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }
        return Answer(status: status, code: object["code"] as? String, body: body ?? Data(), route: route)
    }

    /// Runs the child with `stdin` written through a pipe after launch (a file write's request is
    /// larger than a pipe buffer) and its stdout in an unlinked temp file. Past `timeout` the child is
    /// killed and this throws ``NoAnswer``; so does a child that cannot start.
    static func run(_ binary: URL, arguments: [String], stdin: Data, timeout: Duration) async throws -> Data {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let input = Pipe()
        // Close-on-exec: no other child this app starts inherits a copy of the request (Process dup2s
        // the read end into this child's stdin, which clears the flag there only).
        _ = fcntl(input.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        // A child that exits before reading it all makes the write fail (EPIPE), never SIGPIPE the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input
        let output = try TemporaryOutput()
        process.standardOutput = output.handle
        process.standardError = FileHandle.nullDevice
        let child = Child(process)
        let status: Int32? = await withTaskCancellationHandler {
            await withTaskGroup(of: Int32?.self) { group in
                group.addTask {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
                        child.process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                        // Not started (cancelled first, or it could not start): nothing ran.
                        guard (try? child.launch()) == true else {
                            child.process.terminationHandler = nil
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
                // The request goes in after launch, off this task: the child reads it while it is written.
                let writer = input.fileHandleForWriting
                Thread.detachNewThread {
                    try? writer.write(contentsOf: stdin)
                    try? writer.close()
                }
                defer { group.cancelAll() }
                let first = await group.next() ?? nil
                if first == Int32.min { child.kill() }
                return first == Int32.min ? nil : first
            }
        } onCancel: {
            child.kill()
        }
        try? input.fileHandleForReading.close()
        guard child.started else { throw NoAnswer(dispatched: false) }
        try Task.checkCancellation()
        guard status != nil else { throw NoAnswer(dispatched: true) }
        return output.contents()
    }
}

/// `Process` is not Sendable; it is only launched once and killed while it runs. Launch and kill
/// exclude each other under one lock, and a kill that comes first is remembered (as ProcessBox does),
/// so a cancel or a deadline before launch means no child ever starts.
private final class Child: @unchecked Sendable {
    let process: Process
    private struct State { var launched = false, killed = false }
    private let state = Mutex<State>(State())

    init(_ process: Process) { self.process = process }

    /// Starts the child unless a kill came first; true when it started.
    func launch() throws -> Bool {
        try state.withLock { state in
            if state.killed { return false }
            try process.run()
            state.launched = true
            return true
        }
    }

    var started: Bool { state.withLock { $0.launched } }

    /// SIGKILL to this child only, and only while it runs (never a pid that may be another's by now).
    func kill() {
        state.withLock { state in
            state.killed = true
            guard state.launched, process.isRunning else { return }
            let pid = process.processIdentifier
            if pid > 0 { _ = Darwin.kill(pid, SIGKILL) }
        }
    }
}

/// An unlinked temp file for the child's stdout: a large answer cannot fill a pipe and stall it.
private struct TemporaryOutput {
    let handle: FileHandle

    init() throws {
        var template = Array((NSTemporaryDirectory() + "cmux-machine-io.XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw CloudMachineIO.NoAnswer(dispatched: false) }
        template.withUnsafeBufferPointer { buffer in if let base = buffer.baseAddress { _ = unlink(base) } }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func contents() -> Data {
        // concurrency-allow: a local temp file read once after the child exited, from a nonisolated async caller (never the main actor)
        (try? handle.seek(toOffset: 0)).flatMap { _ in try? handle.readToEnd() } ?? Data()
    }
}
