import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// One short connection to this app's acpmux for a few requests, proven as the person the way
/// the feed bridge's connection is (acpmux `hub/person.rs`: `initialize`, then
/// `_acpmux/person_prove` for its challenge as the second request). The server peer is checked
/// before the first byte (``AcpmuxCheckedLine``). The whole connection lives at most `deadline`;
/// every request still waiting then answers nil.
@MainActor
public final class AcpmuxPersonLine {
    /// The connection itself (internal: tests hold its queue).
    let line: AcpmuxCheckedLine
    private let timer = DemandTimer(owner: "acpmux.person-line")
    private var nextID = 10
    private var waiters: [Int: CheckedContinuation<ResultBox?, Never>] = [:]
    private var closed = false
    /// acpmux took the person proof: this connection may allow.
    public private(set) var isPerson = false
    /// The surfaces this acpmux serves (`initialize`'s `_meta.acpmux.capabilities`, e.g. `machine-consent-v1`).
    public private(set) var capabilities: Set<String> = []
    /// The `error.message` of the last request acpmux refused (its own words, never a secret).
    public private(set) var lastError: String?
    /// The `error.data.reason` of the last request acpmux refused, when it gave one (`consent_required`,
    /// `machine.unlisted`): a word for a program, never a secret.
    public private(set) var lastErrorReason: String?

    /// Why ``isPerson`` is false, in words for a log and a page: another install's daemon, no key of
    /// this app for this daemon (it started or restarted outside this launch), no challenge, or the
    /// daemon's own refusal. Nil while the line is the person's.
    public private(set) var notPersonReason: NotPerson?
    /// The executable of another install's daemon that answered (``connect(_:allowForeign:deadline:)``
    /// with `allowForeign`); nil for the acpmux this app runs.
    public var foreignPeerPath: String? { line.foreignPeerPath }

    /// Why a line is not the person's.
    public enum NotPerson: Equatable, Sendable, CustomStringConvertible {
        /// Another install's daemon (`path`): this app never proves there (``AcpmuxServerPeer`` rule 3).
        case foreignDaemon(path: String)
        /// This app holds no key for this daemon: it neither started nor enrolled this instance.
        case noKey
        /// The daemon sent no person challenge.
        case noChallenge
        /// The daemon refused the proof (its words): it holds another key, as after a restart.
        case refused(String)

        public var description: String {
            switch self {
            case .foreignDaemon: "another install's acpmux holds no key of this app"
            case .noKey: "this app holds no person key for this acpmux instance"
            case .noChallenge: "acpmux sent no person challenge"
            case .refused(let why): "acpmux refused the proof: \(why)"
            }
        }
    }

    /// Why ``connect(_:allowForeign:deadline:)`` got no line.
    public enum OpenFailure: Error, Equatable, Sendable {
        /// Nothing at the socket path: no acpmux runs for this home.
        case noSocket(path: String)
        /// The socket's peer failed the check (``AcpmuxServerPeer/Refusal``'s words), or the connect failed.
        case refused(String)
        /// The daemon closed or did not answer `initialize` within the deadline.
        case noAnswer
        /// Another install's daemon that predates the person challenge (rule 2).
        case olderDaemon(path: String)
    }

    private init(environment: AcpmuxEnvironment, allowForeign: Bool) {
        line = AcpmuxCheckedLine(environment: environment, allowForeign: allowForeign)
    }

    /// Connects, initializes and proves the person; nil when no acpmux answers. A connection
    /// whose proof was refused still reads and denies (``isPerson`` is false).
    public static func open(_ environment: AcpmuxEnvironment, deadline: Duration = .seconds(5)) async -> AcpmuxPersonLine? {
        try? await connect(environment, deadline: deadline).get()
    }

    /// ``connect(_:allowForeign:deadline:)`` with another install's daemon allowed to answer. When this
    /// app's own daemon did not take the proof (this launch never keyed that instance: it restarted
    /// while the app ran, or no pane enrolled it yet), it enrolls it the way Home does
    /// (``AcpmuxApprovalAnswerer/prepareForHome()``: never a hand-off) and connects once more.
    public static func connectEnrolling(_ environment: AcpmuxEnvironment) async -> Result<AcpmuxPersonLine, OpenFailure> {
        await connectEnrolling(environment, enrollRetryDelays: AcpmuxPersonKey.enrollRetryDelays)
    }

    static func connectEnrolling(_ environment: AcpmuxEnvironment,
                                 enrollRetryDelays: [Duration]) async -> Result<AcpmuxPersonLine, OpenFailure> {
        let first = await connect(environment, allowForeign: true)
        guard case .success(let line) = first, !line.isPerson, line.foreignPeerPath == nil, !environment.isAttached
        else { return first }
        switch line.notPersonReason {
        case .noKey?, .refused?: break
        default: return first
        }
        // Once per daemon instance (pid): a daemon that keeps refusing (a DEV one with another launch's key)
        // is not enrolled again on every read, app activation or Mac Screen ticket, and its first line answers.
        guard let status = try? await AcpmuxStatusClient.status(socketPath: environment.socketPath, deadline: .seconds(1)),
              status.serves(home: environment.home), let pid = status.pid,
              AcpmuxPersonKey.claimReenroll(for: environment.socketPath, pid: pid) else { return first }
        // The first line's deadline runs from its connect: closed here, and the answer is a fresh line.
        line.close()
        let outcome = await AcpmuxPersonKey.enrollOutcome(status, environment: environment, mayHandOff: false,
                                                          retryDelays: enrollRetryDelays)
        // A key that never reached the daemon (cancelled, or a refusal that may pass) gives the claim
        // back, so a later read enrolls that instance once more; a refusal for good keeps it.
        if outcome == .unsent || Task.isCancelled {
            AcpmuxPersonKey.releaseReenroll(for: environment.socketPath, pid: pid)
        }
        return await connect(environment, allowForeign: true)
    }

    /// ``open(_:deadline:)`` that says why it got no line. With `allowForeign`, another install's
    /// same-user daemon on this socket answers too (rules 1 and 2 of ``AcpmuxServerPeer``): the line
    /// then reads only, since no proof goes there (rule 3), and ``foreignPeerPath`` names it.
    public static func connect(_ environment: AcpmuxEnvironment, allowForeign: Bool = false,
                               deadline: Duration = .seconds(5)) async -> Result<AcpmuxPersonLine, OpenFailure> {
        guard FileManager.default.fileExists(atPath: environment.socketPath) else {
            return .failure(.noSocket(path: environment.socketPath))
        }
        let connection = AcpmuxPersonLine(environment: environment, allowForeign: allowForeign)
        connection.timer.schedule(after: deadline) { @MainActor [weak connection] in connection?.close() }
        guard let initialized = await connection.start() else {
            connection.close()
            // A socket file nothing answers on (left by a daemon that exited) is no acpmux, not a refused one.
            if connection.line.unreachable { return .failure(.noSocket(path: environment.socketPath)) }
            return .failure(connection.line.refusal.map(OpenFailure.refused) ?? .noAnswer)
        }
        let meta = (initialized["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
        if let path = connection.line.foreignPeerPath {
            // Rule 2: another install's daemon must list the person challenge.
            guard (meta?["features"] as? [String])?.contains("personChallenge") == true else {
                connection.close()
                return .failure(.olderDaemon(path: path))
            }
        }
        connection.capabilities = Set(meta?["capabilities"] as? [String] ?? [])
        let challenge = meta?["personChallenge"] as? [String: Any]
        if let path = connection.line.foreignPeerPath {
            connection.notPersonReason = .foreignDaemon(path: path)
        } else if let nonce = challenge?["nonce"] as? String, let id = challenge?["connection"] as? String {
            if let proof = connection.line.personProof(nonce: nonce, connection: id) {
                connection.isPerson = (await connection.call("_acpmux/person_prove", ["proof": proof]))?["person"] as? Bool ?? false
                if !connection.isPerson { connection.notPersonReason = .refused(connection.lastError ?? "no answer") }
            } else {
                connection.notPersonReason = .noKey
            }
        } else {
            connection.notPersonReason = .noChallenge
        }
        return .success(connection)
    }

    /// One request; its `result`, or nil when it failed or the connection closed.
    public func call(_ method: String, _ params: [String: Any]) async -> [String: Any]? {
        await call(method, params, through: nil)
    }

    /// One request as ``call(_:_:)``; with `gate`, it is written only through it, on the line's queue
    /// right before the bytes go out, and a refused one closes the connection and answers nil
    /// (``AcpmuxCheckedLine/send(_:through:)``).
    public func call(_ method: String, _ params: [String: Any],
                     through gate: (@Sendable (() -> Void) -> Bool)?) async -> [String: Any]? {
        guard !closed else { return nil }
        nextID += 1
        let id = nextID
        let frame = AcpmuxPermissionPrompt.frame(id: id, method: method, params: params)
        let reply: ResultBox? = await withCheckedContinuation { waiter in
            waiters[id] = waiter
            if let gate { line.send(frame, through: gate) } else { line.send(frame) }
        }
        return reply?.value
    }

    /// The pending prompts of `session` (`_acpmux/info`).
    func pending(of session: String) async -> [[String: Any]] {
        (await call("_acpmux/info", ["sessionId": session]))?["pending"] as? [[String: Any]] ?? []
    }

    /// The pending prompts of `session` while this daemon holds it itself: empty when `_acpmux/info`
    /// says a peer holds it (`peer`), as ``AgentPanePendingAsks`` reads it.
    func ownPending(of session: String, chiefHomeID: String? = nil) async -> [[String: Any]] {
        guard let info = await call("_acpmux/info", ["sessionId": session]), info["peer"] == nil else { return [] }
        if let chiefHomeID, !Self.isOwnerSubagent(info, session: session, home: chiefHomeID) { return [] }
        return info["pending"] as? [[String: Any]] ?? []
    }

    /// Home cards can answer only this home's local owner subagents. Turn sessions,
    /// another Chief, the ask floor and peers stay outside this surface.
    nonisolated static func isOwnerSubagent(_ info: [String: Any], session: String, home: String) -> Bool {
        guard session.hasPrefix("local/"), info["sessionId"] as? String == String(session.dropFirst(6)),
              info["peer"] == nil, let tags = info["tags"] as? [String: String],
              tags["mux.parent"] == "optchat-chief:" + home,
              let subagent = tags["optchat.subagent"], !subagent.isEmpty,
              tags["optchat.policy"] != "ask", info["policy"] as? String != "ask",
              tags["cmux.chief.role"] != "turn" else { return false }
        return true
    }

    public func close() {
        guard !closed else { return }
        closed = true
        timer.cancel()
        line.cancel()
        for (_, waiter) in waiters { waiter.resume(returning: nil) }
        waiters = [:]
    }

    /// Sends `initialize` as the first request and waits for its result.
    private func start() async -> [String: Any]? {
        let frame = AcpmuxPermissionPrompt.frame(id: 1, method: "initialize", params: [
            "protocolVersion": 1, "clientInfo": ["name": "cmux-next-approval-banner", "version": "1"],
            "clientCapabilities": [String: Any](),
        ])
        // Lines decode on the line's queue and reach the main actor in batches, never a Task per
        // line (MainActorLineBatch); the close comes after the last line.
        let batch = MainActorLineBatch<Reply> { [weak self] drain in
            guard let self else { return }
            for reply in drain.values {
                if let error = reply.error {
                    lastError = error
                    lastErrorReason = reply.reason
                }
                waiters.removeValue(forKey: reply.id)?.resume(returning: reply.result)
            }
            if drain.overflowed || drain.closed { close() }
        }
        let reply: ResultBox? = await withCheckedContinuation { waiter in
            waiters[1] = waiter
            line.start(send: frame,
                       onLine: { data in if let reply = Self.decode(data) { batch.submit(reply) } },
                       onClose: { batch.close() })
        }
        return reply?.value
    }

    /// One acpmux reply: its request id and its `result` (nil for an error).
    nonisolated struct Reply: Sendable {
        let id: Int
        let result: ResultBox?
        var error: String?
        /// The error's `data.reason`, when it has one.
        var reason: String?
    }

    /// Decodes one line on the line's queue; nil for a line that is not a reply.
    nonisolated static func decode(_ data: Data) -> Reply? {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = (message["id"] as? NSNumber)?.intValue else { return nil }
        let error = message["error"].map { (($0 as? [String: Any])?["message"] as? String) ?? "" }
        let reason = ((message["error"] as? [String: Any])?["data"] as? [String: Any])?["reason"] as? String
        return Reply(id: id, result: error == nil ? ResultBox(message["result"] as? [String: Any] ?? [:]) : nil, error: error,
                     reason: reason)
    }
}
