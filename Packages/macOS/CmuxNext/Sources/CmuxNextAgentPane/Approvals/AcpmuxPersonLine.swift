import CmuxNextWakeups
import Foundation

/// One short connection to this app's acpmux for a few requests, proven as the person the way
/// the feed bridge's connection is (acpmux `hub/person.rs`: `initialize`, then
/// `_acpmux/person_prove` for its challenge as the second request). The server peer is checked
/// before the first byte (``AcpmuxCheckedLine``). The whole connection lives at most `deadline`;
/// every request still waiting then answers nil.
@MainActor
final class AcpmuxPersonLine {
    private let line: AcpmuxCheckedLine
    private let timer = DemandTimer(owner: "acpmux.person-line")
    private var nextID = 10
    private var waiters: [Int: CheckedContinuation<Data?, Never>] = [:]
    private var closed = false
    /// acpmux took the person proof: this connection may allow.
    private(set) var isPerson = false

    private init(environment: AcpmuxEnvironment) {
        line = AcpmuxCheckedLine(environment: environment)
    }

    /// Connects, initializes and proves the person; nil when no acpmux answers. A connection
    /// whose proof was refused still reads and denies (``isPerson`` is false).
    static func open(_ environment: AcpmuxEnvironment, deadline: Duration = .seconds(5)) async -> AcpmuxPersonLine? {
        guard FileManager.default.fileExists(atPath: environment.socketPath) else { return nil }
        let connection = AcpmuxPersonLine(environment: environment)
        connection.timer.schedule(after: deadline) { @MainActor [weak connection] in connection?.close() }
        guard let initialized = await connection.start() else {
            connection.close()
            return nil
        }
        let challenge = ((initialized["_meta"] as? [String: Any])?["acpmux"] as? [String: Any])?["personChallenge"] as? [String: Any]
        if let nonce = challenge?["nonce"] as? String, let id = challenge?["connection"] as? String,
           let proof = connection.line.personProof(nonce: nonce, connection: id) {
            connection.isPerson = (await connection.call("_acpmux/person_prove", ["proof": proof]))?["person"] as? Bool ?? false
        }
        return connection
    }

    /// One request; its `result`, or nil when it failed or the connection closed.
    func call(_ method: String, _ params: [String: Any]) async -> [String: Any]? {
        guard !closed else { return nil }
        nextID += 1
        let id = nextID
        let frame = AcpmuxPermissionPrompt.frame(id: id, method: method, params: params)
        let reply: Data? = await withCheckedContinuation { waiter in
            waiters[id] = waiter
            line.send(frame)
        }
        return reply.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    /// The pending prompts of `session` (`_acpmux/info`).
    func pending(of session: String) async -> [[String: Any]] {
        (await call("_acpmux/info", ["sessionId": session]))?["pending"] as? [[String: Any]] ?? []
    }

    func close() {
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
        let reply: Data? = await withCheckedContinuation { waiter in
            waiters[1] = waiter
            line.start(send: frame,
                       onLine: { [weak self] data in Task { @MainActor in self?.handle(data) } },
                       onClose: { [weak self] in Task { @MainActor in self?.close() } })
        }
        return reply.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    private func handle(_ data: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = (message["id"] as? NSNumber)?.intValue, let waiter = waiters.removeValue(forKey: id) else { return }
        let result = message["error"] == nil
            ? try? JSONSerialization.data(withJSONObject: message["result"] as? [String: Any] ?? [:]) : nil
        waiter.resume(returning: result)
    }
}
