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

    private init(environment: AcpmuxEnvironment) {
        line = AcpmuxCheckedLine(environment: environment)
    }

    /// Connects, initializes and proves the person; nil when no acpmux answers. A connection
    /// whose proof was refused still reads and denies (``isPerson`` is false).
    public static func open(_ environment: AcpmuxEnvironment, deadline: Duration = .seconds(5)) async -> AcpmuxPersonLine? {
        guard FileManager.default.fileExists(atPath: environment.socketPath) else { return nil }
        let connection = AcpmuxPersonLine(environment: environment)
        connection.timer.schedule(after: deadline) { @MainActor [weak connection] in connection?.close() }
        guard let initialized = await connection.start() else {
            connection.close()
            return nil
        }
        let meta = (initialized["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
        connection.capabilities = Set(meta?["capabilities"] as? [String] ?? [])
        let challenge = meta?["personChallenge"] as? [String: Any]
        if let nonce = challenge?["nonce"] as? String, let id = challenge?["connection"] as? String,
           let proof = connection.line.personProof(nonce: nonce, connection: id) {
            connection.isPerson = (await connection.call("_acpmux/person_prove", ["proof": proof]))?["person"] as? Bool ?? false
        }
        return connection
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
    func ownPending(of session: String) async -> [[String: Any]] {
        guard let info = await call("_acpmux/info", ["sessionId": session]), info["peer"] == nil else { return [] }
        return info["pending"] as? [[String: Any]] ?? []
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
            for reply in drain.values { waiters.removeValue(forKey: reply.id)?.resume(returning: reply.result) }
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
    }

    /// Decodes one line on the line's queue; nil for a line that is not a reply.
    nonisolated static func decode(_ data: Data) -> Reply? {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = (message["id"] as? NSNumber)?.intValue else { return nil }
        return Reply(id: id, result: message["error"] == nil ? ResultBox(message["result"] as? [String: Any] ?? [:]) : nil)
    }
}
