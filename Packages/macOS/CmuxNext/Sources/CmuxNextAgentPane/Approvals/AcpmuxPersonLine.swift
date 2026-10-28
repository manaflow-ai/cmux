import CmuxNextCompat
public import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import Foundation

/// One short connection to this app's acpmux for a few requests, proven as the person the way
/// the feed bridge's connection is (acpmux `hub/person.rs`: `initialize`, then
/// `_acpmux/person_prove` for its challenge as the second request). The server peer is checked
/// before the first byte (``AcpmuxCheckedLine``). The whole connection lives at most `deadline`
/// (a `visible` MainDeadline: the banner or dialog that opened it waits on it); every request still
/// waiting then answers nil.
@MainActor
public final class AcpmuxPersonLine {
    private let line: AcpmuxCheckedLine
    private let timer: MainDeadline
    /// The app's main-thread scheduler and this line's owner on it: a refused proof ends its wait there.
    private let mainWork: MainWorkScheduler
    private let owner: MainTaskOwner
    private var nextID = 10
    private var waiters: [Int: OnceContinuation<ResultBox?, OnceContinuationError>] = [:]
    private var closed = false
    /// acpmux took the person proof: this connection may allow.
    public private(set) var isPerson = false

    private init(environment: AcpmuxEnvironment, deadlines: MainDeadlineScheduler) {
        line = AcpmuxCheckedLine(environment: environment)
        timer = MainDeadline(owner: "acpmux.person-line", workClass: .visible, scheduler: deadlines)
        mainWork = deadlines.work
        owner = deadlines.work.board.owner("acpmux.person-line")
    }

    /// Connects, initializes and proves the person; nil when no acpmux answers. A connection
    /// whose proof was refused still reads and denies (``isPerson`` is false). It reads no file on
    /// the caller's thread: a missing socket fails the connect on the line's queue
    /// (``AcpmuxCheckedLine``), which closes this connection and answers nil.
    ///
    /// - Parameters:
    ///   - environment: This app's acpmux.
    ///   - deadlines: The app's one deadline placer (`AppServices.mainDeadlines`), for the connection's limit.
    ///   - deadline: How long the connection may live.
    public static func open(_ environment: AcpmuxEnvironment, deadlines: MainDeadlineScheduler,
                            deadline: Duration = .seconds(5)) async -> AcpmuxPersonLine? {
        let connection = AcpmuxPersonLine(environment: environment, deadlines: deadlines)
        connection.timer.schedule(after: deadline) { [weak connection] in connection?.close() }
        guard let initialized = await connection.start() else {
            connection.close()
            return nil
        }
        let challenge = ((initialized["_meta"] as? [String: Any])?["acpmux"] as? [String: Any])?["personChallenge"] as? [String: Any]
        if let nonce = challenge?["nonce"] as? String, let id = challenge?["connection"] as? String {
            connection.isPerson = await connection.prove(nonce: nonce, connection: id)
        }
        return connection
    }

    /// `_acpmux/person_prove` with the proof for this connection's challenge, made and sent on the
    /// line's queue (``AcpmuxCheckedLine/sendPersonProof(nonce:connection:request:refused:)``);
    /// whether acpmux took it. False with no proof (no key for this daemon) or no reply.
    private func prove(nonce: String, connection: String) async -> Bool {
        guard !closed else { return false }
        nextID += 1
        let id = nextID
        let mainWork = mainWork, owner = owner
        let reply: ResultBox? = try? await withOnceContinuation { (waiter: OnceContinuation<ResultBox?, OnceContinuationError>) in
            waiters[id] = waiter
            line.sendPersonProof(nonce: nonce, connection: connection, request: { proof in
                AcpmuxPermissionPrompt.frame(id: id, method: "_acpmux/person_prove", params: ["proof": proof])
            }, refused: { [weak self] in
                // The banner or dialog that opened this line waits on the answer: a visible task ends its wait.
                mainWork.postFromAnyThread(.visible, owner: owner) { [weak self] in
                    self?.waiters.removeValue(forKey: id)?.resume(returning: nil)
                }
            })
        }
        return reply?.value["person"] as? Bool ?? false
    }

    /// One request; its `result`, or nil when it failed or the connection closed.
    public func call(_ method: String, _ params: [String: Any]) async -> [String: Any]? {
        guard !closed else { return nil }
        nextID += 1
        let id = nextID
        let frame = AcpmuxPermissionPrompt.frame(id: id, method: method, params: params)
        let reply: ResultBox? = try? await withOnceContinuation { (waiter: OnceContinuation<ResultBox?, OnceContinuationError>) in
            waiters[id] = waiter
            line.send(frame)
        }
        return reply?.value
    }

    /// The pending prompts of `session` (`_acpmux/info`).
    func pending(of session: String) async -> [[String: Any]] {
        (await call("_acpmux/info", ["sessionId": session]))?["pending"] as? [[String: Any]] ?? []
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
        let reply: ResultBox? = try? await withOnceContinuation { (waiter: OnceContinuation<ResultBox?, OnceContinuationError>) in
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
        guard let message = (try? JSONSerialization.blockingJSONObject(with: data)) as? [String: Any],
              let id = (message["id"] as? NSNumber)?.intValue else { return nil }
        return Reply(id: id, result: message["error"] == nil ? ResultBox(message["result"] as? [String: Any] ?? [:]) : nil)
    }
}
