public import Foundation
import os

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
        guard let serve else {
            CloudCarrierServe.log.error("carrier link: no bundled cmux-tui, so no carrier for this machine")
            throw CloudLinkError.helperNotRunning(reason: "no bundled cmux-tui")
        }
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
    /// How long one token read may take before it is answered as failed.
    private let readDeadline: Duration
    /// How long the supervisor may leave a connect without a terminal answer.
    private let connectDeadline: Duration
    private var supervisor: ChildProcess?
    private var waiters: [UInt64: CheckedContinuation<String, any Error>] = [:]
    private var waiterDeadlines: [UInt64: Task<Void, Never>] = [:]
    private var lastWaiter: UInt64 = 0
    private var stopped = false
    /// The supervisor's hold in its connector's ``CloudCarrierStreams``: an account end tells it at once.
    private var held: Int?
    /// Why the link ended since the current connect (the supervisor's last `state`), or that it is stopped.
    private(set) var refusal: CloudLinkError? = CloudCarrierServe.exited
    /// The current child's latest connected answer: `owner` or `team` by its `vmk`, `unknown` for a line
    /// without one (never owner). Nil until that child answered once; a new child starts with none.
    private(set) var answer: CloudCallerOwnership?
    private var ownershipObserver: (@Sendable (CloudCallerOwnership) async -> Void)?
    /// The last ownership hand-off: each waits for the one before, so answers arrive in order.
    private var publishing: Task<Void, Never>?
    /// The dials ahead (``dialAhead(limit:keep:)``) that wait for the serve's answer, by the id each asked with.
    private var dials: [UInt64: AsyncStream<Bool>.Continuation] = [:]

    private static let closed = CloudLinkError.disconnected(reason: "closed")
    private static let exited = CloudLinkError.helperNotRunning(reason: "cmux carrier serve exited")

    /// The socket is the machine's `cmux-link-<12 hex>.sock` in this user's private temporary folder
    /// (``CloudPaths``), which the supervisor checks once its child is ready.
    public init(connector: CloudCarrierDial.Connector, paths: CloudPaths) {
        self.init(connector: connector, socket: paths.linkSocket(machineID: connector.dial.machine))
    }

    /// `tokenReadDeadline` and `connectDeadline`: tests shorten the carrier's bounded waits.
    init(connector: CloudCarrierDial.Connector, socket: String,
         tokenReadDeadline: Duration = CloudCarrierServe.tokenReadDeadline,
         connectDeadline: Duration = CloudCarrierServe.connectDeadline) {
        (self.connector, self.socket, self.readDeadline, self.connectDeadline) =
            (connector, socket, tokenReadDeadline, connectDeadline)
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
            waiterDeadlines[waiter] = Task { [weak self] in
                try? await Task.sleep(for: self?.connectDeadline ?? .zero)
                guard !Task.isCancelled else { return }
                await self?.connectTimedOut(waiter)
            }
            guard let supervisor = running() else { return }
            if !supervisor.writeInput(line: #"{"connect":\#(waiter),"keep_refusal":\#(keepingRefusal)}"#) {
                resume(waiter, with: .failure(Self.exited))
            }
        }
    }

    /// Dials the machine ahead of its session, once the serve is up: the supervisor opens one connection on the
    /// serving socket (`carrier supervise`'s `ahead` line), which the serve answers by dialing the machine, so the
    /// session's own first connection only opens a stream on the session held. The supervisor holds that connection,
    /// so the serve keeps the session, until the first connect, a park, a stop or `keep`, whichever is first. True when
    /// the dial connected within `limit`; false when it was refused, the serve is not up or is stopped, the supervisor
    /// holds no connection for it, or `limit` passed first (the dial then goes on in the serve, and a session that
    /// connects meanwhile joins it).
    public func dialAhead(limit: Duration, keep: Duration) async -> Bool {
        guard !stopped, !connector.isFenced, let supervisor else { return false }
        lastWaiter &+= 1
        let dial = lastWaiter
        let (answers, sink) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        dials[dial] = sink
        guard supervisor.writeInput(line: #"{"ahead":\#(dial),"keep_ms":\#(Int(min(3_600_000, max(0, keep / .milliseconds(1)))))}"#) else {
            dials[dial] = nil
            return false
        }
        let dialed = await Self.race(limit) { () async -> Bool in
            for await dialed in answers { return dialed }
            return false
        }
        dials[dial] = nil
        return dialed ?? false
    }

    /// The serve's answer to the dials ahead that wait: `dialed`, or false once it is refused or gone.
    private func answerDials(_ dialed: Bool) {
        for sink in dials.values {
            sink.yield(dialed)
            sink.finish()
        }
        dials = [:]
    }

    /// Ends the serve for good: its child stops, and every connect waiting resumes closed.
    public func stop() {
        stopped = true
        refusal = Self.closed
        answerDials(false)
        supervisor?.writeInput(line: #"{"stop":true}"#)
        supervisor?.closeInput()
    }

    /// Ends the child while the machine is paused; the next connect starts a fresh one.
    public func park() {
        answerDials(false)
        if supervisor?.writeInput(line: #"{"park":true}"#) == false {
            Self.log.error("carrier supervise \(self.connector.dial.machine, privacy: .public): the park did not reach the supervisor")
        }
    }

    /// The running supervisor, started when none runs; nil (each waiter resumed) when it cannot start.
    private func running() -> ChildProcess? {
        if let supervisor { return supervisor }
        let process = ChildProcess(executable: connector.cli, arguments: connector.dial.superviseArguments(socket: socket))
        do {
            try process.startHoldingInput()
        } catch {
            Self.log.error("carrier supervise \(self.connector.dial.machine, privacy: .public): did not start: \(error.localizedDescription, privacy: .public)")
            finish(Result.failure(CloudLinkError.helperNotRunning(reason: "cmux carrier supervise did not start: \(error.localizedDescription)")))
            return nil
        }
        supervisor = process
        // Its children carry this account's token: an account end (``CloudCarrierStreams/endAll()``) stops it at
        // once; one that came first already did.
        if let streams = connector.streams {
            held = streams.hold(generation: connector.generation) { [weak self] in
                process.writeInput(line: #"{"account_ended":true}"#)
                process.closeInput()
                // task-owner: one hop that tells the serve its account ended
                Task { await self?.stop() }
            }
        }
        // task-owner: ends with the supervisor's stderr and its exit
        Task { [weak self, lines = process.stderrLines] in
            for await line in lines { await self?.received(line, from: process) }
            let status = await process.waitForExit()
            await self?.exited(process, status: status)
        }
        return process
    }

    private func received(_ text: String, from process: ChildProcess) {
        guard process === supervisor,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        if let step = object["log"] as? String {
            // One link step, worded, bounded and stripped of credentials by the supervisor (`supervise_wire::log_line`).
            Self.log.notice("carrier supervise \(self.connector.dial.machine, privacy: .public): \(String(step.prefix(500)), privacy: .public)")
        } else if let read = object["read_token"] as? UInt64 {
            readToken(read, for: process)
        } else if let ids = object["resume"] as? [UInt64] {
            var result: Result<String, CloudLinkError> = if let socket = object["socket"] as? String { .success(socket) } else {
                .failure((object["error"] as? [String: Any]).flatMap(CloudLinkError.init(wire:)) ?? Self.exited)
            }
            // A ready line that came after an account end hands the old account's socket to no one.
            if case .success = result, connector.isFenced { result = .failure(Self.closed) }
            for id in ids { resume(id, with: result) }
        } else if let state = object["state"] as? [String: Any] {
            refusal = stopped ? Self.closed : (state["refusal"] as? [String: Any]).flatMap(CloudLinkError.init(wire:))
            answer = (state["answer"] as? String).flatMap(CloudCallerOwnership.init(rawValue:))
            // A refusal, or a connected answer, is the dial's outcome; a state with neither says nothing yet.
            if refusal != nil { answerDials(false) } else if answer != nil { answerDials(true) }
        } else if let dial = object["ahead"] as? UInt64, object["held"] as? Bool == false {
            // The supervisor holds no connection for this dial ahead (no serve child is ready, or one is held).
            if let sink = dials.removeValue(forKey: dial) {
                sink.yield(false)
                sink.finish()
            }
        } else if let word = object["publish"] as? String, let caller = CloudCallerOwnership(rawValue: word) {
            answer = caller
            answerDials(true)
            let (previous, observer) = (publishing, ownershipObserver)
            // task-owner: one observer call, after the one before it
            publishing = Task {
                await previous?.value
                await observer?(caller)
            }
        }
    }

    /// The longest a token read takes before it is answered as failed: the supervisor waits for this answer
    /// with its lease held, and every connect of the session joins that wait, so an answer that never comes
    /// wedges the machine's link for good (2026-11-15).
    static let tokenReadDeadline: Duration = .seconds(75)

    /// The app bounds every connect so a helper that starts and then stops speaking cannot leave the Cloud
    /// link in `connecting` forever. This covers the supervisor's 10-second lease wait, 90-second token
    /// read and 15-second ready wait, with a small margin for handoff.
    static let connectDeadline: Duration = .seconds(120)

    /// Answers the supervisor's token read `read` with the connector's environment, always: within
    /// ``tokenReadDeadline`` an access token, `fenced` or why there is none.
    private func readToken(_ read: UInt64, for process: ChildProcess) {
        let (connector, machine, deadline) = (connector, connector.dial.machine, readDeadline)
        Self.log.notice("carrier supervise \(machine, privacy: .public): token read \(read) asked")
        // task-owner: one token read, ended by its answer or its deadline; the supervisor drops an answer whose launch moved on
        Task.detached(priority: .userInitiated) {
            let started = ContinuousClock.now
            let reply = await Self.tokenReply(read, connector: connector, deadline: deadline)
            let line = Self.line(reply) ?? Self.line(["token": read, "error": CloudLinkError.helperNotRunning(reason: "the token answer did not encode").wire]) ?? ""
            let wrote = process.writeInput(line: line, patience: .seconds(2))
            let kind = reply["env"] != nil ? "env" : reply["fenced"] != nil ? "fenced" : "error"
            let ms = Int(started.duration(to: .now) / .milliseconds(1))
            if wrote {
                Self.log.notice("carrier supervise \(machine, privacy: .public): token read \(read) answered \(kind, privacy: .public) after \(ms) ms")
            } else {
                Self.log.error("carrier supervise \(machine, privacy: .public): token read \(read) answer (\(kind, privacy: .public)) did not reach the supervisor after \(ms) ms")
            }
        }
    }

    /// The `token` line's object for read `read`: the environment, `fenced`, or the error; a read that outlives
    /// `deadline` (an auth call that never returns) is answered as failed, and its late result is dropped.
    static func tokenReply(_ read: UInt64, connector: CloudCarrierDial.Connector, deadline: Duration) async -> [String: Any] {
        let outcome = await Self.race(deadline) { () async -> Result<[String: String], any Error> in
            do { return .success(try await connector.environment()) } catch { return .failure(error) }
        }
        var reply: [String: Any] = ["token": read]
        switch outcome {
        case .success(let environment)?:
            // A switch during the read hands the token to no one.
            if connector.isFenced { reply["fenced"] = true } else { reply["env"] = environment }
        case .failure(let error as CloudLinkError)? where error == CloudCarrierDial.Connector.fenced:
            reply["fenced"] = true
        case .failure(let error)?:
            let failure = (error as? CloudLinkError) ?? .helperNotRunning(reason: "cmux carrier serve has no access token: \(error)")
            reply["error"] = failure.wire
        case nil:
            reply["error"] = CloudLinkError.helperNotRunning(reason: "the access token read took longer than \(deadline)").wire
        }
        return reply
    }

    /// `operation`'s value, or nil once `limit` passed first. Never joins a late `operation` (one that ignores
    /// its cancellation), unlike a task group, which waits for every child before it returns.
    static func race<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
        let (results, sink) = AsyncStream.makeStream(of: T?.self)
        // task-owner: the operation; its late value goes to a finished stream
        let work = Task { sink.yield(await operation()); sink.finish() }
        // task-owner: the deadline; cancelled by the answer
        let timer = Task {
            // wakeup-allow: one-shot deadline of one token read
            try? await Task.sleep(for: limit)
            sink.yield(nil)
            sink.finish()
        }
        var first: T?
        for await value in results { first = value; break }
        timer.cancel()
        if first == nil { work.cancel() }
        return first
    }

    /// The carrier link's steps, one line each. Notice and error only: release builds persist those, so
    /// `log show --predicate 'subsystem == "com.cmuxterm.app.next" AND category == "cloud.carrier"'` reads a
    /// nightly's link failure; an info or debug line is not kept (tests/test_cloud_carrier_os_log.py).
    static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.carrier")

    private func exited(_ process: ChildProcess, status: Int32) {
        guard process === supervisor else { return }
        supervisor = nil
        if let held { connector.streams?.release(held) }
        held = nil
        answer = nil
        answerDials(false)
        let ended = stopped ? Self.closed : Self.supervisorExited(status: status, stderr: process.stderrText)
        if stopped {
            Self.log.notice("carrier supervise \(self.connector.dial.machine, privacy: .public): exited with status \(status) after a stop")
        } else {
            Self.log.error("carrier supervise \(self.connector.dial.machine, privacy: .public): \(String(String(describing: ended).prefix(500)), privacy: .public)")
        }
        refusal = ended
        finish(.failure(ended))
    }

    /// The supervisor itself exited: its status and its last stderr line that is not one of its JSON lines
    /// (a usage refusal, a panic), so the link's end tells it apart from the serve child's exit.
    static func supervisorExited(status: Int32, stderr: String) -> CloudLinkError {
        let last = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("{") }
        let reason = "cmux carrier supervise exited with status \(status)"
        return .helperNotRunning(reason: last.map { "\(reason); its last stderr line: \($0.prefix(300))" } ?? reason)
    }

    private func finish(_ result: Result<String, CloudLinkError>) {
        let waiting = waiters
        waiters = [:]
        for timer in waiterDeadlines.values { timer.cancel() }
        waiterDeadlines = [:]
        for continuation in waiting.values { continuation.resume(with: result.mapError { $0 as any Error }) }
    }

    /// Fails one silent connect. A later supervisor answer finds no waiter and is ignored, so a late line
    /// cannot resume a continuation twice or revive a link that already reported its failure.
    private func connectTimedOut(_ waiter: UInt64) {
        guard waiters[waiter] != nil else { return }
        Self.log.error("carrier supervise \(self.connector.dial.machine, privacy: .public): connect \(waiter) did not answer after \(self.connectDeadline, privacy: .public)")
        resume(waiter, with: .failure(.helperNotRunning(reason: "cmux carrier supervise did not answer connect within \(connectDeadline)")))
    }

    private func resume(_ waiter: UInt64, with result: Result<String, CloudLinkError>) {
        waiterDeadlines.removeValue(forKey: waiter)?.cancel()
        waiters.removeValue(forKey: waiter)?.resume(with: result.mapError { $0 as any Error })
    }

    /// `object` as one JSON line; nil when it does not encode (never a `{}` the supervisor skips).
    private static func line(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(decoding: data, as: UTF8.self)
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
        case "helper_refused": self = .helperRefused(code: text("code"), message: text("message"))
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
        case .helperRefused(let code, let message): ["kind": "helper_refused", "code": code, "message": message]
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
