import CmuxNextCloud
import CmuxNextCompat
public import Foundation

/// Why a run ended without its report line.
public struct HostCLIStop: LocalizedError, Equatable, Sendable {
    /// The exit status, or nil when the process did not start.
    public var status: Int32?
    /// The last line the process wrote to stderr, or the launch error.
    public var message: String

    public init(status: Int32?, message: String) {
        self.status = status
        self.message = message
    }

    /// The process's own words (the Add Machine card shows it on the step that stopped).
    public var errorDescription: String? { message }
}

/// Runs the app's own `cmux-tui` (the binary `DaemonLauncher` resolves) for the Add Machine card and
/// hands its stdout over line by line as the pipe delivers it, never by polling. Cancelling the
/// consumer terminates the process.
public struct HostCLI: Sendable {
    public let binary: URL
    public let environment: @Sendable () async -> [String: String]

    public init(binary: URL, environment: @escaping @Sendable () async -> [String: String]) {
        self.binary = binary
        self.environment = environment
    }

    /// `host candidates --json [--probe]`: the Tailscale peers' JSON, nil when there is no Tailscale,
    /// or the run failed or timed out. Without `probe` it is one local tailscale call; `--probe` also
    /// tries ssh to the user's own machines (at most 32, eight at a time, 5 s each).
    public func candidates(probe: Bool) async -> Data? {
        let argv = [binary.path, "acp", "host", "candidates", "--json"] + (probe ? ["--probe"] : [])
        guard let result = try? await SSHProcessRunner.run(argv, environment: await Self.grouped(environment()),
                                                           deadline: .seconds(probe ? 30 : 15), label: "host candidates",
                                                           stop: Self.stop),
              result.status == 0 else { return nil }
        return Data(result.stdout.utf8)
    }

    /// The stdout of one short `cmux-tui <arguments>` run that prints JSON (`device list --json`,
    /// `device remove ID --yes --json`); nil when it failed or passed `deadline`.
    public func json(_ arguments: [String], deadline: Duration = .seconds(20), label: String) async -> Data? {
        guard let result = try? await SSHProcessRunner.run([binary.path] + arguments, environment: await Self.grouped(environment()),
                                                           deadline: deadline, label: label, stop: Self.stop),
              result.status == 0 else { return nil }
        return Data(result.stdout.utf8)
    }

    /// The stdout lines of `cmux-tui <arguments>` (an `acp host enroll|doctor --json` run). A run that
    /// exits non-zero ends the stream with ``HostCLIStop``; a run whose report says not ok exits
    /// non-zero too, after its report line.
    public func lines(_ arguments: [String]) -> AsyncThrowingStream<String, any Error> {
        let binary = binary, environment = environment
        // A run writes a line per step and a report; the cap only bounds a runaway writer.
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(1024)) { continuation in
            let process = Process(), gate = RunGate()
            // task-owner: ends when the process starts, or with the stream's cancel
            let start = Task {
                let env = await Self.grouped(environment())
                Self.run(process, gate: gate, binary: binary, arguments: arguments, environment: env, into: continuation)
            }
            continuation.onTermination = { _ in
                start.cancel()
                // Before the start: it sees the gate closed and never runs. After it: stopped here.
                if gate.close(), process.isRunning { Self.stop(process) }
            }
        }
    }

    /// The run's environment, asking it to lead its own process group (acpmux
    /// `lead_process_group_if_asked`), so ``stop(_:)`` reaches the ssh it starts.
    nonisolated static func grouped(_ environment: [String: String]) -> [String: String] {
        environment.merging(["ACPMUX_PROCESS_GROUP": "1"]) { _, new in new }
    }

    /// SIGTERM to the run's process group when it leads one, so the ssh and scp it started stop with
    /// it; else to the process alone (never the app's own group).
    nonisolated static func stop(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        kill(getpgid(pid) == pid ? -pid : pid, SIGTERM)
    }

    private static func run(_ process: Process, gate: RunGate, binary: URL, arguments: [String], environment: [String: String],
                            into continuation: AsyncThrowingStream<String, any Error>.Continuation) {
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let lines = LineSink(), errors = LineSink(keep: 16)
        let stdoutEnded = ExitLatch()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            switch handle.readReady() {
            case .bytes(let data): for line in lines.append(data) { continuation.yield(line) }
            case .retry: return
            case .end:
                handle.readabilityHandler = nil
                for line in lines.flush() { continuation.yield(line) }
                stdoutEnded.finish(0)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            switch handle.readReady() {
            case .bytes(let data): _ = errors.append(data)
            case .retry: return
            case .end: handle.readabilityHandler = nil
            }
        }
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            // task-owner: one wait for stdout's last bytes after the exit, bounded
            Task {
                // Output can trail the exit; never wait for it unbounded.
                _ = try? await withDeadline(.milliseconds(500), label: "host output") { await stdoutEnded.awaitValue() }
                if status == 0 {
                    continuation.finish()
                } else {
                    let message = errors.tail
                    continuation.finish(throwing: HostCLIStop(status: status, message: message))
                }
            }
        }
        // The stream may end (Cancel) at any point up to here; the gate decides under one lock
        // whether this start still runs, and a cancel that lands after it stops the process.
        do {
            try gate.start { try process.run() }
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch {
            continuation.finish(throwing: HostCLIStop(status: nil, message: error.localizedDescription))
        }
    }
}

/// Orders a run's start against its stream's end: ``start(_:)`` runs the launch only while the gate
/// is open, under the same lock ``close()`` takes, so a cancel either comes first (no launch) or
/// after the launch (``close()`` says it started, and the caller stops the process).
final class RunGate: Sendable {
    private let state = Mutex((closed: false, started: false))

    /// Launches unless closed; throws `CancellationError` when it was.
    func start(_ launch: () throws -> Void) throws {
        try state.withLock { state in
            guard !state.closed else { throw CancellationError() }
            try launch()
            state.started = true
        }
    }

    /// Closes the gate; whether the launch already happened (the caller stops the process).
    func close() -> Bool {
        state.withLock { state in
            state.closed = true
            return state.started
        }
    }
}

/// A ``LineBuffer`` the pipe's handlers share across threads.
final class LineSink: Sendable {
    private let buffer: Mutex<LineBuffer>

    init(keep: Int = 0) {
        buffer = Mutex(LineBuffer(keep: keep))
    }

    func append(_ data: Data) -> [String] { buffer.withLock { $0.append(data) } }

    func flush() -> [String] { buffer.withLock { $0.flush() } }

    /// The last non-empty line seen, the unterminated one included.
    var tail: String {
        buffer.withLock { buffer in (buffer.kept + buffer.flush()).last { !$0.isEmpty } ?? "" }
    }
}

/// Splits pipe chunks into lines; a line split across two chunks comes out whole.
struct LineBuffer {
    /// How many of the last lines to keep (stderr's tail); 0 keeps none.
    let keep: Int
    private var pending = Data()
    /// The last lines seen, when asked to keep them (stderr's tail).
    private(set) var kept: [String] = []

    init(keep: Int = 0) {
        self.keep = keep
    }

    /// The complete lines in `data` and what came before it.
    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        if keep > 0 {
            kept = Array((kept + lines.map { $0.trimmingCharacters(in: .whitespaces) }).filter { !$0.isEmpty }.suffix(keep))
        }
        return lines
    }

    /// The unterminated last line, if any.
    mutating func flush() -> [String] {
        guard !pending.isEmpty else { return [] }
        defer { pending = Data() }
        return [String(decoding: pending, as: UTF8.self)]
    }
}
