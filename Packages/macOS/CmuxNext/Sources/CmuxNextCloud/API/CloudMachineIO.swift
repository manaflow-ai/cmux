public import CMUXAuthCore
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

/// A machine's exec, file and SCP calls and the team's network on a Worker machines daemon
/// (``CloudDaemon/workerMachines(baseURL:accessToken:teamID:appVersion:machineIO:installToken:buildSpace:)``), as the
/// person's Stack session in the cmux team (`x-cmux-team`), never the refresh token. Each is one daemon call; the
/// HTTP, its deadlines and the answer's checks are cmux-cloud-api's. The sign-in daemon refuses them before any call
/// (``requireWorker(code:)``).
extension CloudDaemon {
    /// A Worker machine's (the Cloud app server link's) calls on the cmux API Worker (`baseURL`:
    /// ``CloudConfiguration/ownerAPIBaseURL(environment:)``), as the person's Stack session (`accessToken`) in the cmux
    /// team `teamID` (the install token's team claim, the team the app link lists its machines in), like
    /// ``CloudOwnerAPIClient``. Never this Mac's install token for exec or files: a Mac install has no execute grant
    /// (cmux-platform#89). `machineIO`: the bundled cmux every call goes through. `installToken`: this Mac's install
    /// token, for the one call that takes an install, not a session (``listNetworks()``).
    public static func workerMachines(baseURL: URL, accessToken: @escaping @Sendable () async throws -> String,
                                      teamID: @escaping TeamID, appVersion: String = "cmux-next", machineIO: CloudMachineIO? = nil,
                                      installToken: (@Sendable () async throws -> String)? = nil,
                                      buildSpace: CMUXBuildSpaceState = .nightly) -> CloudDaemon {
        var daemon = CloudDaemon(baseURL: baseURL, tokens: { (try await accessToken(), "") }, teamID: teamID, appVersion: appVersion,
                                 sendsStackSession: false, buildSpace: buildSpace)
        daemon.machineIO = machineIO
        daemon.installToken = installToken
        return daemon
    }

    /// cmux-platform's machine routes, named in a decoding failure's context.
    var machinePath: String { "/v1/cloud/machines" }

    /// The daemon's `machine.io` exec (`POST /v1/cloud/machines/{id}/exec`): runs `command` in the machine's shell.
    /// The route caps `timeoutMs` at 5 minutes.
    public func exec(_ id: String, command: String, timeoutMs: Int = 30_000) async throws -> CloudExecResult {
        try await machine("exec", id, ["command": command, "timeout_ms": timeoutMs], timeout: .milliseconds(timeoutMs) + .seconds(5))
    }

    /// Starts the desktop closure on an existing running Cloud machine: the daemon's
    /// `machine.setup_desktop` (cmux-platform's `POST /v1/cloud/machines/{id}/desktop`). The platform route
    /// performs the root-owned capability repair; the app never asks the guest shell to invent it.
    public func setupDesktop(_ id: String) async throws {
        try requireWorker()
        // The route's own deadline is 30 s in Rust; this one only bounds a child that hangs.
        _ = try await daemon("machine.setup_desktop", ["id": id], timeout: .seconds(60))
    }

    /// Lists a guest directory.
    public func listFiles(_ id: String, path: String) async throws -> [CloudFileEntry] {
        struct List: CloudServerModel {
            static var cloudModelKind: String { "file_entries" }
            var entries: [CloudFileEntry]
            init(from decoder: any Decoder) throws { entries = try [CloudFileEntry](from: decoder) }
        }
        return try await machine("dir", id, ["path": path], timeout: .seconds(20), as: List.self).entries
    }

    /// Reads a guest file; its bytes come back base64 in the JSON answer.
    public func readFile(_ id: String, path: String) async throws -> CloudFileContents {
        try await machine("read", id, ["path": path], timeout: .seconds(120))
    }

    /// Writes a guest file atomically.
    public func writeFile(_ id: String, path: String, data: Data, mode: Int? = nil) async throws {
        var request: [String: any Sendable] = ["path": path, "data_base64": data.base64EncodedString()]
        if let mode { request["mode"] = mode }
        _ = try await machine("write", id, request, timeout: .seconds(120), as: Ignored.self)
    }

    public func makeDirectory(_ id: String, path: String) async throws {
        _ = try await machine("mkdir", id, ["path": path], timeout: .seconds(20), as: Ignored.self)
    }

    public func removeFile(_ id: String, path: String) async throws {
        _ = try await machine("remove", id, ["path": path], timeout: .seconds(120), as: Ignored.self)
    }

    public func statFile(_ id: String, path: String) async throws -> CloudFileStat {
        try await machine("stat", id, ["path": path], timeout: .seconds(20))
    }

    /// Mints a short-lived private SCP route: the daemon's `vm.scp_endpoint` (cmux-platform's
    /// `POST /v1/cloud/machines/{id}/ssh-endpoint`). The public key is the only key material sent; the caller owns the secret.
    public func prepareSCP(_ id: String, publicKey: String) async throws -> CloudSCPEndpoint {
        // Rust answers only a safe route (port 22, user cmux, an ed25519 host key, not expired) and
        // cmux-cloud-machine reads it again; any other answer throws ``CloudAPIError/decoding(_:)``.
        try requireWorker()
        // The route's own deadline is 100 s in Rust; this one only bounds a child that hangs.
        let body = try await daemon("vm.scp_endpoint", ["id": id, "publicKey": publicKey], timeout: .seconds(130))
        return try CloudMachineRules().answer(body, as: CloudSCPEndpoint.self, context: "\(machinePath)/\(id)/ssh-endpoint")
    }

    /// The team's Cloud network: the daemon's `vm.networks` (cmux-platform's `GET /v1/host/network/target`)
    /// on a Worker machines daemon, sent as this Mac's install (`installToken`, auth `worker`; the route
    /// refuses a Stack session), never classic Cloud. A team has one network, named by its team id (what
    /// tunnel attach takes), with its provider mesh as `meshId`; a team with no mesh yet (404) has none.
    public func listNetworks() async throws -> [CloudNetwork] {
        guard !sendsStackSession, let installToken else { throw CloudAPIError.transport("the Cloud network list is a cmux API Worker route") }
        var install = self
        install.tokens = { (try await installToken(), "") }
        let body = try await install.daemon("vm.networks", [:], timeout: .seconds(50), auth: "worker")
        do {
            return try JSONDecoder().decode([CloudNetwork].self, from: body)
        } catch {
            throw CloudAPIError.decoding("cloud.vm.networks: \(error)")
        }
    }

    /// Machine, file, SCP and preview calls are cmux-platform's: the sign-in daemon refuses them with a
    /// 501 before any call, never a wait on a route NEXT does not serve.
    func requireWorker(code: String = "machine.unsupported") throws {
        guard !sendsStackSession else { throw CloudAPIError.http(status: 501, code: code, message: nil) }
    }

    /// An answer whose body is not read.
    struct Ignored: Decodable {}

    /// One exec or file operation: refused on the sign-in daemon, else the daemon's `machine.io`
    /// (cmux-cloud-api `machine::worker`: the provider directly with a client session when it can, these
    /// routes otherwise; that choice and every fallback are Rust's), decoded exactly as the route's own
    /// answer. No bundled cmux is `transport` ("cmux is not available"), like every daemon call. A child
    /// that started and gave no answer is never sent again: the op may have run.
    private func machine<T: Decodable>(_ op: String, _ id: String, _ fields: [String: any Sendable], timeout: Duration,
                                       as type: T.Type = T.self) async throws -> T {
        try requireWorker()
        var args = fields
        args["op"] = op
        args["machine"] = id
        let body: Data
        do {
            // The child's own HTTP deadlines end first; this one only bounds a child that hangs.
            body = try await daemon("machine.io", args, timeout: timeout + .seconds(30))
        } catch CloudAPIError.timedOut("cloud.machine.io") {
            throw CloudAPIError.transport("cmux did not answer; the \(op) may have run")
        }
        if T.self == Ignored.self, let ignored = Ignored() as? T { return ignored }
        return try CloudMachineRules().answer(body, as: T.self, context: "\(machinePath)/\(id)/\(op == "exec" ? "exec" : "fs/\(op)")")
    }
}
