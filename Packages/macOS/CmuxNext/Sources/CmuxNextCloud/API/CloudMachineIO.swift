public import CmuxNextWakeups
public import Foundation
import CmuxNextCompat
import CmuxNextDaemon
import Darwin

/// The bundled cmux-tui, through which the app's daemon Cloud calls go (`cmux cloud api`, cmux-tui
/// `cli/cloud_api.rs`; a Worker machine's exec and file routes are its `machine.io`, which talks to the
/// machine's provider directly with a short-lived client session and falls back to the cmux API's own
/// routes on its own). This type only forwards: one JSON request on the child's stdin (the credential
/// never goes in argv), one JSON answer line back.
public struct CloudMachineIO: Sendable {
    /// The `cmux` binary (`Contents/Resources/bin/cmux`).
    public let binary: URL
    /// Where cmux-tui keeps its client sessions (0700; one 0600 file per machine and person).
    public let cacheDirectory: URL
    /// The app's blocking-work lanes: every file call of a call (the answer's temp file and its read) runs on
    /// `.files`, never on the cooperative pool (threading-model.md).
    let work: BackgroundWork

    public init(binary: URL, cacheDirectory: URL, work: BackgroundWork) {
        self.binary = binary
        self.cacheDirectory = cacheDirectory
        self.work = work
    }

    /// The app's: the bundled cmux at `bundleResources/bin/cmux` (or the cmux-tui built from source that
    /// `environment`'s `CMUX_NEXT_TUI_BIN` names) and its client sessions in `cloudRoot/client-sessions`.
    /// It touches no file (the Cloud service makes it on the main thread at start): a build without that cmux finds
    /// out on its first call, which throws ``NoAnswer`` (`dispatched` false), never an HTTP fallback.
    public init?(bundleResources: URL?, cloudRoot: URL, work: BackgroundWork,
                 environment: [String: String] = ProcessInfo.processInfo.environment) {
        let binary: URL
        if let override = environment[DaemonLauncher.binaryOverrideKey], !override.isEmpty {
            binary = URL(fileURLWithPath: override)
        } else {
            guard let resources = bundleResources else { return nil }
            binary = resources.appendingPathComponent("bin/cmux")
        }
        self.init(binary: binary,
                  cacheDirectory: cloudRoot.appendingPathComponent("client-sessions", isDirectory: true), work: work)
    }

    /// The child gave no answer line. `dispatched` false: it never started (no binary, a cancel first),
    /// so nothing ran.
    /// `dispatched` true: it started and then crashed, timed out or printed nothing usable, so the
    /// operation may have run and a change must not be sent a second time.
    struct NoAnswer: Error { var dispatched: Bool }

    /// One `cmux cloud api` call (cmux-tui `cli/cloud_api.rs`): `input` (the request JSON) on the child's stdin,
    /// its stdout back (one answer line). Throws ``NoAnswer`` as ``run(_:arguments:stdin:timeout:work:)`` does.
    @concurrent func cloudAPI(_ input: Data, timeout: Duration) async throws -> Data {
        try await Self.run(binary, arguments: ["cloud", "api"], stdin: input, timeout: timeout, work: work)
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
                    // concurrency-allow: on its own feeder thread after launch; a kill at the deadline or a cancel ends it (EPIPE)
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
                OpenDescriptors.noteBudgetSoon()  // every child launch: a leak shows in the log as it passes the bound
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

// MARK: CloudDaemon transport

/// ``CloudDaemon``'s one transport: each call is one `cmux cloud api` child run through ``CloudMachineIO``.
extension CloudDaemon {
    /// `cloud.<call>` with `args`: answers its body as JSON, or throws its failure as a ``CloudAPIError``.
    /// No bundled cmux is `transport` ("cmux is not available"); there is no HTTP fallback. `timeout` bounds the
    /// child (a child past it is killed: `timedOut`, since the call may have run). `auth` is the credential's kind as
    /// cmux-cloud-api reads it: `owner` (the Stack session) or `worker` (this Mac's install token).
    func daemon(_ call: String, _ args: [String: any Sendable], timeout: Duration, auth: String = "owner") async throws -> Data {
        let run: @Sendable (Data, Duration) async throws -> Data
        if let daemonCall {
            run = daemonCall
        } else if let machineIO {
            run = { input, timeout in try await machineIO.cloudAPI(input, timeout: timeout) }
        } else {
            throw CloudAPIError.transport("cmux is not available")
        }
        let access: String
        do { access = try await tokens().access } catch { throw CloudAPIError.notSignedIn }
        var request: [String: any Sendable] = ["call": call, "api": baseURL.absoluteString, "auth": auth, "credential": access,
                                               "app_version": appVersion, "args": args]
        if let team = await teamID() { request["team"] = team }
        let output: Data
        do {
            output = try await run(try JSONSerialization.data(withJSONObject: request), timeout)
        } catch let noAnswer as CloudMachineIO.NoAnswer {
            // Never started: nothing ran. Started and then killed or crashed: the call may have run.
            if noAnswer.dispatched { throw CloudAPIError.timedOut("cloud.\(call)") }
            throw CloudAPIError.transport("cmux is not available")
        }
        guard let line = output.split(separator: UInt8(ascii: "\n")).last(where: { !$0.isEmpty }),
              let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
            throw CloudAPIError.transport("cmux did not answer cloud.\(call)")
        }
        guard object["ok"] as? Bool == true else { throw Self.daemonFailure(object["error"] as? [String: Any] ?? [:], call: call, baseURL: baseURL) }
        return try JSONSerialization.data(withJSONObject: object["body"] ?? NSNull(), options: .fragmentsAllowed)
    }

    /// `cmux_cloud_api`'s `Failure` JSON (`kind` and its fields) as the ``CloudAPIError`` case it names.
    static func daemonFailure(_ error: [String: Any], call: String, baseURL: URL) -> CloudAPIError {
        func text(_ name: String) -> String? { (error[name] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch text("kind") {
        case "timed_out": return .timedOut(text("path") ?? "cloud.\(call)")
        case "transport": return .transport(text("message") ?? "cmux did not answer cloud.\(call)")
        case "no_backend": return .noBackend(baseURL)
        case "http":
            guard let status = error["status"] as? Int else { return .decoding("cloud.\(call): no status") }
            return .http(status: status, code: text("code"), message: text("message"), action: text("action"), traceId: text("trace_id"))
        case "plan_required":
            return .planRequired(message: text("message"), upgradeURL: text("upgrade_url").flatMap { URL(string: $0) }, plan: text("plan") ?? "pro")
        case "decoding": return .decoding(text("message") ?? "cloud.\(call)")
        default: return .decoding("cloud.\(call): unreadable failure")
        }
    }
}
