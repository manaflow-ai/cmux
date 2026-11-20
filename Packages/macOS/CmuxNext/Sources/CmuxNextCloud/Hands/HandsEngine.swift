import CmuxNextCompat
public import CmuxNextDaemon
import Darwin
public import Foundation

/// The bundled `cmux cloud hands` engine (cmux-tui `cli/cloud_hands.rs`, rules in
/// `cmux_cloud_wire::hands`): it follows the owner's user socket, reads the waiting requests,
/// calls the hand routes and builds every text the app signs. This type only carries JSON lines:
/// commands to the child's stdin, events from its stdout. One child serves the app's whole life;
/// the app's exit closes its stdin, which ends it.
@MainActor
final class HandsEngine {
    /// Why a call gave no answer: the engine's own refusal (`kind`, `status`, `code`, `message`),
    /// or no engine at all.
    struct Refusal: Error, Sendable, Equatable {
        var kind: String
        var status: Int?
        var code: String?
        var message: String
    }

    private let cli: BundledExecutable
    private var process: Process?
    private var input: FileHandle?
    private var launching = false
    /// Lines written before the child runs, in order.
    private var outbox: [Data] = []
    private var waiting: [UInt64: CheckedContinuation<Result<Data, Refusal>, Never>] = [:]
    private var nextID: UInt64 = 0
    /// The most stdout lines that wait for the main actor.
    private static let lineBuffer = 4096
    private var reader: Task<Void, Never>?
    /// Writes off the main thread: a child that stalls never blocks it.
    private let writes = DispatchQueue(label: "cmux.cloud.hands.stdin", qos: .userInitiated)

    /// Each event line but `reply` (`token`, `hands`, `pending`, `settled`, `log`).
    var onEvent: ((_ event: String, _ object: [String: Any]) -> Void)?
    /// The child ended (crash or quit): nothing it reported stands.
    var onExit: (() -> Void)?

    init(cli: BundledExecutable) { self.cli = cli }

    /// Sends one command (`t`), starting the child first when it is not running.
    func send(_ command: [String: Any]) {
        guard let line = try? JSONSerialization.data(withJSONObject: command) else { return }
        let data = line + Data("\n".utf8)
        if let input {
            writes.async { try? input.write(contentsOf: data) }
            return
        }
        outbox.append(data)
        launch()
    }

    /// One `call`: its `value` as JSON bytes, decoded as `Reply`.
    func call<Reply: Decodable>(_ op: String, _ params: [String: Any] = [:], as: Reply.Type = Reply.self) async throws -> Reply {
        nextID += 1
        let id = nextID
        var command = params
        (command["t"], command["id"], command["op"]) = ("call", id, op)
        let answer = await withCheckedContinuation { continuation in
            waiting[id] = continuation
            send(command)
        }
        switch answer {
        case let .success(data):
            do { return try JSONDecoder().decode(Reply.self, from: data) } catch { throw Refusal(kind: "decoding", message: "\(op): \(error)") }
        case let .failure(refusal):
            throw refusal
        }
    }

    private func launch() {
        guard !launching, process == nil else { return }
        launching = true
        // task-owner: HandsEngine.launch: one start of the child; it ends when the child runs or cannot.
        Task { [weak self] in
            let binary = await self?.cli.resolve()
            guard let self else { return }
            self.launching = false
            guard let binary, (try? self.run(binary)) != nil else {
                self.ended()
                return
            }
            let lines = self.outbox
            self.outbox = []
            if let input = self.input { self.writes.async { for line in lines { try? input.write(contentsOf: line) } } }
        }
    }

    private func run(_ binary: URL) throws {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["cloud", "hands"]
        let stdin = Pipe(), stdout = Pipe()
        let reader = stdin.fileHandleForReading, writer = stdin.fileHandleForWriting
        // Close-on-exec: no other child inherits the engine's stdin; a write to an engine that
        // exited fails (EPIPE) and never raises SIGPIPE in the app.
        _ = fcntl(reader.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writer.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = reader
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // Overflow: a main actor that fell this far behind ends the stream, so the engine ends and
        // starts again with a fresh read, never with a dropped event.
        let (lines, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingOldest(Self.lineBuffer))
        let splitter = LineSplitter()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            switch handle.readReady() {
            case .bytes(let data):
                for line in splitter.append(data) {
                    if case .dropped = continuation.yield(line) {
                        handle.readabilityHandler = nil
                        continuation.finish()
                        return
                    }
                }
            case .retry: return
            case .end: handle.readabilityHandler = nil; continuation.finish()
            }
        }
        try process.run()
        try? reader.close()
        (self.process, input) = (process, writer)
        // task-owner: HandsEngine.run: reads the child's stdout until it ends (the child exited).
        self.reader = Task { [weak self] in
            for await line in lines { self?.handle(line) }
            self?.ended()
        }
    }

    private func handle(_ line: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let event = object["event"] as? String else { return }
        if event != "reply" {
            onEvent?(event, object)
            return
        }
        guard let id = (object["id"] as? NSNumber)?.uint64Value, let waiter = waiting.removeValue(forKey: id) else { return }
        if object["ok"] as? Bool == true {
            let value = object["value"] ?? NSNull()
            waiter.resume(returning: .success((try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)) ?? Data("null".utf8)))
        } else {
            let error = object["error"] as? [String: Any] ?? [:]
            waiter.resume(returning: .failure(Refusal(kind: error["kind"] as? String ?? "transport", status: error["status"] as? Int,
                                                      code: error["code"] as? String, message: error["message"] as? String ?? "")))
        }
    }

    private func ended() {
        if let process, process.isRunning { process.terminate() }
        (process, input, reader, outbox) = (nil, nil, nil, [])
        let failed = waiting
        waiting = [:]
        for waiter in failed.values { waiter.resume(returning: .failure(Refusal(kind: "transport", message: "the hands engine is not running"))) }
        onExit?()
    }
}
