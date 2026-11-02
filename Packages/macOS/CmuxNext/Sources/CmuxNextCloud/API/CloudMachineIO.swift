public import CmuxNextWakeups
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
    /// Which binaries speak `machine-io` (``speaksMachineIO()``). An instance, not a static: it lives as
    /// long as the one machine IO the app's Cloud service makes and injects into its machines client
    /// (copies of the client share it); a test passes its own.
    let probes: Probes
    /// The app's blocking-work lanes: every file call of a call (the probe's stats, the answer's temp file and
    /// its read) runs on `.files`, never on the cooperative pool (threading-model.md).
    let work: BackgroundWork

    public init(binary: URL, cacheDirectory: URL, work: BackgroundWork) {
        self.init(binary: binary, cacheDirectory: cacheDirectory, probes: Probes(), work: work)
    }

    init(binary: URL, cacheDirectory: URL, probes: Probes, work: BackgroundWork) {
        self.binary = binary
        self.cacheDirectory = cacheDirectory
        self.probes = probes
        self.work = work
    }

    /// The app's: the bundled cmux at `bundleResources/bin/cmux` and its client sessions in `cloudRoot/client-sessions`.
    /// It touches no file (the Cloud service makes it on the main thread at start): whether that cmux is there is
    /// asked by the first call's probe, off the main thread (``speaksMachineIO()``), and a build without it sends every
    /// call over HTTP.
    public init?(bundleResources: URL?, cloudRoot: URL, work: BackgroundWork) {
        guard let resources = bundleResources else { return nil }
        self.init(binary: resources.appendingPathComponent("bin/cmux"),
                  cacheDirectory: cloudRoot.appendingPathComponent("client-sessions", isDirectory: true), work: work)
    }

    /// The probe answers, by binary path and modification date.
    final class Probes: Sendable {
        private let known = Mutex<[String: Bool]>([:])

        init() {}

        subscript(key: String) -> Bool? {
            get { known.withLock { $0[key] } }
            set { known.withLock { $0[key] = newValue } }
        }
    }

    /// The route's answer: `status` 0 is none at all (then `code` says why: `timed_out` or `transport`).
    struct Answer: Sendable {
        var status: Int
        var code: String?
        var body: Data
        var route: String
    }

    /// The child gave no answer line. `dispatched` false: it never started (no binary, a cancel first,
    /// a cmux without `machine-io`) or said it took nothing (route `none`), so nothing ran and the caller may take the HTTP route.
    /// `dispatched` true: it started and then crashed, timed out or printed nothing usable, so the
    /// operation may have run and a change must not be sent a second time.
    struct NoAnswer: Error { var dispatched: Bool }

    /// Off the caller's actor (`@concurrent`): the app calls the machine routes from main-actor handlers. The file
    /// calls (the probe's stats, the temp file and its read) go on `work`'s files lane; the answer's parse runs here.
    @concurrent func perform(_ request: [String: any Sendable], timeout: Duration) async throws -> Answer {
        // A bundled cmux from before `machine-io` never runs the call: it goes over HTTP.
        guard try await speaksMachineIO() else { throw NoAnswer(dispatched: false) }
        var request = request
        request["cache_dir"] = cacheDirectory.path
        let input = try JSONSerialization.data(withJSONObject: request)
        let output = try await Self.run(binary, arguments: ["cloud", "machine-io"], stdin: input, timeout: timeout, work: work)
        guard let line = output.split(separator: UInt8(ascii: "\n")).last(where: { !$0.isEmpty }),
              let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let status = object["status"] as? Int, let route = object["route"] as? String else { throw NoAnswer(dispatched: true) }
        guard route == "direct" || route == "proxy" else { throw NoAnswer(dispatched: route != "none") }
        let body = object["body"].flatMap { $0 is NSNull ? nil : try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }
        return Answer(status: status, code: object["code"] as? String, body: body ?? Data(), route: route)
    }

    /// Whether this binary has `cloud machine-io`: an empty request makes one that does answer
    /// `route: none` without doing anything; an older cmux prints no such line. Asked once per binary
    /// (path and modification date, so an app update asks again); a probe that itself fails is not kept. A build
    /// without the binary speaks none, and that is kept.
    @concurrent func speaksMachineIO() async throws -> Bool {
        let binary = binary
        // Both stats in one trip to the files lane: the modification date keys the cache.
        let (modified, executable) = try await work.run(.userVisible, mayBlock: .files) {
            ((try? binary.blockingResourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
             FileManager.checked.isExecutableFile(atPath: binary.path))
        }
        let key = "\(binary.path)@\(modified?.timeIntervalSince1970 ?? 0)"
        if let known = probes[key] { return known }
        guard executable else {
            probes[key] = false
            return false
        }
        let output: Data
        do {
            output = try await Self.run(binary, arguments: ["cloud", "machine-io"], stdin: Data("{}".utf8), timeout: .seconds(10), work: work)
        } catch is NoAnswer {
            return false
        }
        let line = output.split(separator: UInt8(ascii: "\n")).last(where: { !$0.isEmpty })
        let object = line.flatMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
        let speaks = object?["route"] is String
        probes[key] = speaks
        return speaks
    }

    /// Runs the child with `stdin` written through a pipe after launch (a file write's request is
    /// larger than a pipe buffer) and its stdout in an unlinked temp file. Past `timeout` the child is
    /// killed and this throws ``NoAnswer``; so does a child that cannot start. The temp file is made and read on
    /// `work`'s files lane; a lane that refuses (quit) throws `CancellationError`, before the launch or after the exit.
    @concurrent static func run(_ binary: URL, arguments: [String], stdin: Data, timeout: Duration,
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
                feeder.name = "cmux.cloud.machine-io.stdin"
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
        var template = Array((NSTemporaryDirectory() + "cmux-machine-io.XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw CloudMachineIO.NoAnswer(dispatched: false) }
        template.withUnsafeBufferPointer { buffer in if let base = buffer.baseAddress { _ = unlink(base) } }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func contents() -> Data {
        // concurrency-allow: a local temp file read once after the child exited, on the BackgroundWork files lane (run)
        (try? handle.seek(toOffset: 0)).flatMap { _ in try? handle.blockingReadToEnd() } ?? Data()
    }
}
