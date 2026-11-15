public import Foundation

/// The carrier's link of a Cloud machine (design/cloud-carrier.md): one `cmux carrier serve` child for the
/// session (``CloudCarrierServe``), whose private socket dials the machine's `mux` once per connection, the
/// way the old link socket did. Every client of the machine's daemon gets that socket: the daemon
/// connection (its retries and reconnects too, ``redials``), the CLI's copies, moves, uploads and updates,
/// and the phone. The owner answer is the current serve child's latest connected line (its `vmk`; a line
/// without one is never owner), which also updates the live link; the machine record's creator rule
/// applies only before that child answered at all.
public struct CloudCarrierResolver: CloudLinkResolver {
    private let serve: CloudCarrierServe?
    private let ownership: @Sendable () async -> CloudCallerOwnership

    /// `serve`: nil when the app has no bundled CLI (every connect then fails as the helper not running).
    /// `ownership`: the signed-in caller and the machine, read at each connect.
    public init(serve: CloudCarrierServe?, ownership: @escaping @Sendable () async -> CloudCallerOwnership) {
        self.serve = serve
        self.ownership = ownership
    }

    public func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
        guard let serve else { throw CloudLinkError.helperNotRunning(reason: "no bundled cmux-tui") }
        let socket = try await serve.socketPath()
        // The grant's answer on this child's latest connected line; the record's creator rule only before any.
        let answered = await serve.answer
        let caller = if let answered { answered } else { await ownership() }
        return CloudLinkSocket(key: key, path: socket, generation: nil, callerOwnsVM: caller == .owner, callerIsTeammate: caller == .team)
    }

    /// The serve child's socket for the Cloud app server: started when it does not run; the refusal this
    /// link reports is left as it is.
    public func carrierSocket(_ key: CloudLinkKey) async throws -> String {
        guard let serve else { throw CloudLinkError.helperNotRunning(reason: "no bundled cmux-tui") }
        return try await serve.socketPath(keepingRefusal: true)
    }

    /// Why the serve child's last dial was refused since this connect, or that the child is gone.
    public func refusal(_ key: CloudLinkKey) async -> CloudLinkError? { await serve?.refusal }

    public var redials: Bool { true }

    public func observeOwnership(_ key: CloudLinkKey, _ update: @escaping @Sendable (CloudCallerOwnership) async -> Void) async {
        await serve?.observeOwnership(update)
    }

    public func regrant(_ key: CloudLinkKey, unlessAnsweredWithin fresh: Duration) async -> CloudCallerOwnership? {
        await serve?.regrant(unlessAnsweredWithin: fresh)
    }

    /// Stops the session's `carrier serve` for good (machine removed, sign-out, quit): a later `open` fails closed.
    public func close(_ key: CloudLinkKey) async { await serve?.stop() }

    /// Stops the session's `carrier serve` while the machine is paused; the next `open` (a resume) starts another.
    public func park(_ key: CloudLinkKey) async { await serve?.park() }
}

/// One Cloud session's `cmux carrier serve --machine <vm_id> --socket <path>` (#37278). Its whole lifecycle
/// (launch, token refresh, stop, park, the account fence) is one state machine in Rust: `cmux carrier
/// supervise` (cmux-tui `carrier/supervise.rs`, `carrier/serve_machine.rs`), which runs the serve child. This
/// actor is only the app's edge: it starts the supervisor at the first connect and sends it each connect, a
/// park, a stop or the account's end as one JSON line; it answers the supervisor's token reads with the
/// connector's environment (the signed-in account's fresh access token, or that the account ended); and it
/// keeps the refusal and answer the supervisor last reported. ``stop()`` and an account end are terminal: a
/// later connect fails as closed (a new session makes a new serve). A socket handed out after the connector's
/// account ended goes to no one.
public actor CloudCarrierServe {
    private let connector: CloudCarrierDial.Connector
    private let socket: String
    private var supervisor: ChildProcess?
    private var waiters: [UInt64: CheckedContinuation<String, any Error>] = [:]
    private var lastWaiter: UInt64 = 0
    private var stopped = false
    /// The supervisor's hold in its connector's ``CloudCarrierStreams``: an account end tells it at once.
    private var held: Int?
    /// Why the link ended since the current connect (the supervisor's last `state`), or that it is stopped.
    private(set) var refusal: CloudLinkError? = CloudCarrierServe.exited
    /// The current child's latest connected answer: `owner` or `team` by its `vmk`, `unknown` for a line
    /// without one (never owner). Nil until that child answered once; a new child starts with none.
    private(set) var answer: CloudCallerOwnership?
    /// When ``answer`` last came (a connection's or a regrant's `publish` line).
    private var answeredAt: ContinuousClock.Instant?
    /// ``regrant(unlessAnsweredWithin:)`` calls waiting for the supervisor's `regranted` line, by waiter id.
    private var regrants: [UInt64: AsyncStream<CloudCallerOwnership?>.Continuation] = [:]
    /// How long a regrant waits for its answer: one dial, whose ticket and handshake fit well inside it.
    static let regrantDeadline: Duration = .seconds(30)
    private var ownershipObserver: (@Sendable (CloudCallerOwnership) async -> Void)?
    /// The last ownership hand-off: each waits for the one before, so answers arrive in order.
    private var publishing: Task<Void, Never>?

    private static let closed = CloudLinkError.disconnected(reason: "closed")
    private static let exited = CloudLinkError.helperNotRunning(reason: "cmux carrier serve exited")

    /// The socket is the machine's `cmux-link-<12 hex>.sock` in this user's private temporary folder
    /// (``CloudPaths``), which the supervisor checks once its child is ready.
    public init(connector: CloudCarrierDial.Connector, paths: CloudPaths) {
        self.init(connector: connector, socket: paths.linkSocket(machineID: connector.dial.machine))
    }

    init(connector: CloudCarrierDial.Connector, socket: String) {
        (self.connector, self.socket) = (connector, socket)
    }

    func observeOwnership(_ update: @escaping @Sendable (CloudCallerOwnership) async -> Void) { ownershipObserver = update }

    /// The serving socket. Throws ``CloudLinkError`` when the serve does not get ready, and `closed` once stopped
    /// or once the connector's account ended. `keepingRefusal`: another client asks (the Cloud app server), so
    /// the refusal the session's own connect reads stays.
    public func socketPath(keepingRefusal: Bool = false) async throws -> String {
        guard !stopped, !connector.isFenced else { throw Self.closed }
        lastWaiter &+= 1
        let waiter = lastWaiter
        return try await withCheckedThrowingContinuation { continuation in
            waiters[waiter] = continuation
            guard let supervisor = running() else { return }
            if !supervisor.writeInput(line: Self.line(["connect": waiter, "keep_refusal": keepingRefusal])) {
                waiters.removeValue(forKey: waiter)?.resume(throwing: Self.exited)
            }
        }
    }

    /// Asks the ready serve child for a fresh grant (cmux#40201 F1): its held session answers every connection
    /// with its first dial's `vmk`, so a teammate an owner shared the machine with stays `team` until it is
    /// gone. The supervisor sends serve `{"regrant":true}`, which retires that session and dials once with a
    /// fresh grant; its answer becomes ``answer`` and reaches the live link (the ownership observer) before
    /// this returns it. `fresh`: an answer younger than this is current enough, and nothing is asked. Nil when
    /// no child is ready, its dial was refused, or no answer came within ``regrantDeadline``.
    public func regrant(unlessAnsweredWithin fresh: Duration = .zero) async -> CloudCallerOwnership? {
        guard !stopped, !connector.isFenced, let supervisor else { return nil }
        if let answeredAt, let answer, answeredAt.duration(to: .now) < fresh { return answer }
        lastWaiter &+= 1
        let waiter = lastWaiter
        let (answers, continuation) = AsyncStream.makeStream(of: CloudCallerOwnership?.self, bufferingPolicy: .bufferingNewest(1))
        regrants[waiter] = continuation
        guard supervisor.writeInput(line: Self.line(["regrant": waiter])) else {
            regrants.removeValue(forKey: waiter)?.finish()
            return nil
        }
        let answered = try? await withDeadline(Self.regrantDeadline, label: "carrier regrant") { () -> CloudCallerOwnership? in
            for await answer in answers { return answer }
            return nil
        }
        regrants.removeValue(forKey: waiter)?.finish()
        guard let caller = answered ?? nil else { return nil }
        // The supervisor's `publish` line came first: the live link has this answer once its hand-off ran.
        await publishing?.value
        return caller
    }

    /// Ends the serve for good: its child stops, and every connect waiting resumes closed.
    public func stop() {
        stopped = true
        refusal = Self.closed
        supervisor?.writeInput(line: Self.line(["stop": true]))
        supervisor?.closeInput()
    }

    /// Ends the child while the machine is paused; the next connect starts a fresh one.
    public func park() {
        supervisor?.writeInput(line: Self.line(["park": true]))
    }

    /// The running supervisor, started when none runs; nil (each waiter resumed) when it cannot start.
    private func running() -> ChildProcess? {
        if let supervisor { return supervisor }
        let process = ChildProcess(executable: connector.cli, arguments: connector.dial.superviseArguments(socket: socket))
        do {
            try process.startHoldingInput()
        } catch {
            finish(Result.failure(CloudLinkError.helperNotRunning(reason: "cmux carrier supervise did not start: \(error.localizedDescription)")))
            return nil
        }
        supervisor = process
        // Its children carry this account's token: an account end (``CloudCarrierStreams/endAll()``) stops it at
        // once; one that came first already did.
        if let streams = connector.streams {
            held = streams.hold(generation: connector.generation) { [weak self] in
                process.writeInput(line: Self.line(["account_ended": true]))
                process.closeInput()
                // task-owner: one hop that tells the serve its account ended
                Task { await self?.stop() }
            }
        }
        // task-owner: ends with the supervisor's stderr and its exit
        Task { [weak self, lines = process.stderrLines] in
            for await line in lines { await self?.received(line, from: process) }
            _ = await process.waitForExit()
            await self?.exited(process)
        }
        return process
    }

    private func received(_ text: String, from process: ChildProcess) {
        guard process === supervisor,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        if let read = object["read_token"] as? UInt64 {
            readToken(read, for: process)
        } else if let ids = object["resume"] as? [UInt64] {
            var result: Result<String, CloudLinkError> = if let socket = object["socket"] as? String { .success(socket) } else {
                .failure((object["error"] as? [String: Any]).flatMap(CloudLinkError.init(wire:)) ?? Self.exited)
            }
            // A ready line that came after an account end hands the old account's socket to no one.
            if case .success = result, connector.isFenced { result = .failure(Self.closed) }
            for id in ids { waiters.removeValue(forKey: id)?.resume(with: result.mapError { $0 as any Error }) }
        } else if let state = object["state"] as? [String: Any] {
            refusal = stopped ? Self.closed : (state["refusal"] as? [String: Any]).flatMap(CloudLinkError.init(wire:))
            answer = (state["answer"] as? String).flatMap(CloudCallerOwnership.init(rawValue:))
            if answer == nil { answeredAt = nil }
        } else if let ids = object["regranted"] as? [UInt64] {
            let caller = (object["answer"] as? String).flatMap(CloudCallerOwnership.init(rawValue:))
            for id in ids {
                guard let waiter = regrants.removeValue(forKey: id) else { continue }
                waiter.yield(caller)
                waiter.finish()
            }
        } else if let word = object["publish"] as? String, let caller = CloudCallerOwnership(rawValue: word) {
            answer = caller
            answeredAt = .now
            let (previous, observer) = (publishing, ownershipObserver)
            // task-owner: one observer call, after the one before it
            publishing = Task {
                await previous?.value
                await observer?(caller)
            }
        }
    }

    /// Answers the supervisor's token read `read` with the connector's environment.
    private func readToken(_ read: UInt64, for process: ChildProcess) {
        let connector = connector
        // task-owner: one token read; the supervisor drops an answer whose launch moved on
        Task {
            var reply: [String: Any] = ["token": read]
            do {
                let environment = try await connector.environment()
                // A switch during the read hands the token to no one.
                if connector.isFenced { reply["fenced"] = true } else { reply["env"] = environment }
            } catch let error as CloudLinkError where error == CloudCarrierDial.Connector.fenced {
                reply["fenced"] = true
            } catch {
                let failure = (error as? CloudLinkError) ?? .helperNotRunning(reason: "cmux carrier serve has no access token: \(error)")
                reply["error"] = failure.wire
            }
            process.writeInput(line: Self.line(reply))
        }
    }

    private func exited(_ process: ChildProcess) {
        guard process === supervisor else { return }
        supervisor = nil
        if let held { connector.streams?.release(held) }
        held = nil
        answer = nil
        answeredAt = nil
        refusal = stopped ? Self.closed : Self.exited
        finish(.failure(stopped ? Self.closed : Self.exited))
        let waiting = regrants
        regrants = [:]
        for waiter in waiting.values { waiter.yield(nil); waiter.finish() }
    }

    private func finish(_ result: Result<String, CloudLinkError>) {
        let waiting = waiters
        waiters = [:]
        for continuation in waiting.values { continuation.resume(with: result.mapError { $0 as any Error }) }
    }

    private static func line(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8), as: UTF8.self)
    }
}

extension CloudLinkError {
    /// `carrier supervise`'s error object (`{"kind":…}`, cmux-tui `carrier/supervise_wire.rs`); nil for a kind it
    /// does not name.
    init?(wire object: [String: Any]) {
        let text = { (key: String) in object[key] as? String ?? "" }
        switch object["kind"] as? String {
        case "disconnected": self = .disconnected(reason: text("reason"))
        case "revoked": self = .revoked(reason: text("reason"))
        case "helper_not_running": self = .helperNotRunning(reason: text("reason"))
        case "unsafe_socket": self = .unsafeSocket(text("detail"))
        case "open_directory": self = .openDirectory(path: text("path"), parent: object["parent"] as? Bool ?? false)
        case "invalid_answer": self = .invalidAnswer(text("detail"))
        case "not_up": self = .notUp(state: text("state"))
        case "failed": self = .failed(code: text("code"), message: text("message"))
        case "unsupported": self = .unsupported
        default: return nil
        }
    }

    /// This error as ``init(wire:)`` reads it.
    var wire: [String: Any] {
        switch self {
        case .disconnected(let reason): ["kind": "disconnected", "reason": reason]
        case .revoked(let reason): ["kind": "revoked", "reason": reason]
        case .helperNotRunning(let reason): ["kind": "helper_not_running", "reason": reason]
        case .unsafeSocket(let detail): ["kind": "unsafe_socket", "detail": detail]
        case .openDirectory(let path, let parent): ["kind": "open_directory", "path": path, "parent": parent]
        case .invalidAnswer(let detail): ["kind": "invalid_answer", "detail": detail]
        case .notUp(let state): ["kind": "not_up", "state": state]
        case .failed(let code, let message): ["kind": "failed", "code": code, "message": message]
        case .unsupported: ["kind": "unsupported"]
        }
    }
}

extension CloudCallerOwnership {
    /// A grant's `vmk`: `owner` or `team`; nil for anything else (no answer yet).
    public init?(vmk: String?) {
        switch vmk {
        case "owner": self = .owner
        case "team": self = .team
        default: return nil
        }
    }

    /// The record's rule (cloud-machine-ops.ts `CloudVmKind`): the machine's creator is its `owner`, any
    /// other member of its team is `team`; unknown while either id is missing.
    public init(creator: String?, caller: String?) {
        guard let creator, let caller, !creator.isEmpty, !caller.isEmpty else { self = .unknown; return }
        self = creator == caller ? .owner : .team
    }
}
