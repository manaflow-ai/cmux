public import Foundation
import CmuxNextCompat

/// A task this app handed off (a sandboxed Run, hq#3367, or a hand-off), as the follower keeps it across a
/// relaunch. Plain data: the rules that change it are Rust's (cmux-cloud-tasks `model` and `follower`).
public nonisolated struct SandboxRunRecord: Codable, Hashable, Sendable {
    public var id: String
    /// The task as the person wrote it.
    public var task: String
    /// The page's attempt key (the create's idempotency key): which tab's send this Run is.
    public var key: String
    /// The signed-in user that created it: only that user's session may read it.
    public var user: String
    /// The team the create went to; the waits go there too.
    public var team: String?
    public var started: Date
    /// The source's position after the last wait (a hand-off's version), so a wait passes it.
    public var cursor: Int?
    /// The notices already told (``CloudTaskNotice/key``, newest last, bounded): each is told once.
    public var told: [String]?
    /// When the task last changed (its cursor moved, or a hand-off's listing showed its last change);
    /// the source's maximum age counts from here (nil: from ``started``).
    public var changed: Date?
    /// Its current turn runs (a hand-off `starting` or `running`), as last read: not given up for
    /// the source's maximum age since it changed, only for that long without an answer.
    public var running: Bool?
    /// The acpmux host of a hand-off's chat, when this app made it (nil: unknown).
    public var host: String?
    /// Sent from an incognito window's chat: never saved for the next launch, and its banner names nothing.
    public var incognito: Bool?

    public init(id: String, task: String, key: String, user: String, team: String?, started: Date) {
        (self.id, self.task, self.key, self.user, self.team, self.started) = (id, task, key, user, team, started)
    }
}

/// Something to tell about a task that goes on (a hand-off's turn done, failed or waiting for
/// the person): told once per `key`, so the same state read again tells nothing.
public nonisolated struct CloudTaskNotice: Hashable, Sendable, Decodable {
    /// What makes it the same notice (a hand-off's turn and status, `"2:done"`).
    public var key: String
    public var outcome: SandboxRunEnd.Outcome

    public init(key: String, outcome: SandboxRunEnd.Outcome) { (self.key, self.outcome) = (key, outcome) }
}

/// A Run that ended here, kept across a relaunch for a week: a late
/// ``SandboxRunFollower/follow(_:)`` never tells it again, and its banner's click still finds its card.
public nonisolated struct SandboxRunEnded: Codable, Hashable, Sendable {
    public var record: SandboxRunRecord
    public var outcome: SandboxRunEnd.Outcome
    /// The final snapshot's receipt alone (`{"receipt": …}`), what the Run's card shows; nil when it had none.
    public var card: Data?
    public var at: Date
    /// Its end was told (``SandboxRunFollower/onEnd`` ran), or is never to be told (this app cancelled
    /// it). An end saved but not yet told is told at the next launch.
    public var told: Bool
}

/// How a followed Run ended.
public nonisolated struct SandboxRunEnd: Sendable {
    /// `needsYou` is no end: the task waits for the person and goes on after (a hand-off's notice).
    public enum Outcome: String, Codable, Sendable { case succeeded, failed, timedOut, cancelled, needsYou }
    public var record: SandboxRunRecord
    public var outcome: Outcome
    /// The terminal snapshot (`{run, attempts, artifacts, receipt}`) as the server sent it; a
    /// replayed end carries the saved receipt alone (`{receipt}`).
    public var snapshot: Data
    /// Told again at a launch: the last launch saved the end but may have died around its banner.
    public var replayed = false

    public init(record: SandboxRunRecord, outcome: Outcome, snapshot: Data, replayed: Bool = false) {
        (self.record, self.outcome, self.snapshot, self.replayed) = (record, outcome, snapshot, replayed)
    }
}

/// The daemon's sandboxed Runs (cmux-tui `cloud.runs.*`); the account pin and the poll's one-account read are CloudCLICall.swift's.
extension CloudDaemon {
    /// The app's Cloud account a send was made under (its user id and its team id, nil: personal).
    public struct RunAccount: Sendable, Equatable {
        public var user: String
        public var team: String?
        public init(user: String, team: String?) {
            self.user = user
            self.team = team
        }
    }

    /// It goes under ``runningAs(_:)``'s account, the one the person sent under (none: `notSignedIn`, nothing sent);
    /// the daemon refuses the create (`run_account_changed`) when the app is on another one by then, so a switch
    /// never sends the task elsewhere. An `incognito` Run's reply and error are never written to the daemon's store.
    public func createSandboxRun(task: String, agent: String? = nil, connection: String? = nil, image: String? = nil, timeoutMs: Int? = nil,
                                 idempotencyKey: String = UUID().uuidString, incognito: Bool = false) async throws -> Data {
        guard let runAccount else { throw CloudAPIError.notSignedIn }
        var args: [String: any Sendable] = ["task": task, "idempotencyKey": idempotencyKey,
                                            "expectedAccount": ["user_id": runAccount.user, "team_id": runAccount.team ?? ""] as [String: any Sendable]]
        if incognito { args["incognito"] = true }
        if let agent, !agent.isEmpty { args["agent"] = agent }
        if let connection, !connection.isEmpty { args["connection"] = connection }
        if let image, !image.isEmpty { args["image"] = image }
        if let timeoutMs { args["timeoutMs"] = timeoutMs }
        return try await daemon("runs.create", args, timeout: .seconds(20))
    }

    /// The daemon's `cloud.runs.wait`: the snapshot once the Run is terminal or after
    /// `timeoutMs` (held at most 10 s), with its receipt when it has one.
    public func waitRun(_ id: String, timeoutMs: Int) async throws -> Data {
        let wait = max(0, min(timeoutMs, 10_000))
        return try await daemon("runs.wait", ["id": id, "timeoutMs": wait], timeout: .milliseconds(wait + 10_000))
    }

    /// One sandboxed Run to its end: create it, then long-poll ``waitRun(_:timeoutMs:)`` (10 s a
    /// call) until the snapshot carries its receipt. Everything (sign-in tokens included) runs under
    /// one deadline, the task's timeout plus `teardown` (boot, the last output and the VM destroy)
    /// plus a minute for the calls themselves, so the caller always gets an answer. The poll stops
    /// at the receipt, at the first error, or at that deadline (`timedOut`); the daemon deletes
    /// the machine either way. `idempotencyKey` names this one send: a create whose answer was lost is
    /// sent once more under it, which returns the same Run, never a second paid one; after a switch of
    /// account the daemon refuses it (`run_account_changed`) rather than start one under the new account, as it
    /// refuses any create once the app is off ``runningAs(_:)``'s account. Answers the final
    /// snapshot (`{run, attempts, artifacts, receipt}`) as JSON. `follow` (``SandboxRunFollower``) waits in place of the poll here.
    public func runSandbox(task: String, agent: String? = nil, connection: String? = nil, timeoutMs: Int = 600_000, idempotencyKey: String = UUID().uuidString,
                           incognito: Bool = false,
                           teardown: Duration = .seconds(180), callsMargin: Duration = .seconds(60),
                           now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, follow: (@Sendable (_ id: String) async throws -> Data)? = nil) async throws -> [String: Any] {
        let bound = Duration.milliseconds(timeoutMs) + teardown + callsMargin
        let data = try await SandboxDeadline.race(bound) {
            try await self.sandboxSnapshot(task: task, agent: agent, connection: connection, timeoutMs: timeoutMs, key: idempotencyKey, incognito: incognito,
                                           deadline: now() + .milliseconds(timeoutMs) + teardown, now: now, follow: follow)
        }
        guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudAPIError.decoding("cloud.runs: no snapshot")
        }
        return snapshot
    }

    /// The daemon's `cloud.runs.cancel`; the Run's machine is deleted before it answers.
    public func cancelRun(_ id: String) async throws -> Data {
        try await daemon("runs.cancel", ["id": id], timeout: .seconds(60))
    }
}

/// A deadline that holds even when the work ignores cancellation (a sign-in token read that never
/// returns): the caller is answered at the bound and the work is cancelled, never awaited. A task
/// group would wait for its cancelled child, so ``withDeadline`` can't promise that.
nonisolated final class SandboxDeadline<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var cancels: [@Sendable () -> Void] = []
        /// The caller was cancelled, possibly before the continuation was registered: no work starts.
        var cancelled = false
    }
    private let state = Mutex(State())

    static func race(_ bound: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await race(bound, timeout: { CloudAPIError.timedOut("cloud.runs") }, work)
    }

    /// ``race(_:_:)`` with the error the bound throws (`timeout`): a Cloud link step names itself.
    static func race(_ bound: Duration, timeout: @escaping @Sendable () -> any Error,
                     _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = SandboxDeadline<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = gate.state.withLock { state -> Bool in
                    if !state.cancelled { state.continuation = continuation }
                    return state.cancelled
                }
                // Cancelled first: answered now, and no Run is created.
                guard !cancelled else { return continuation.resume(throwing: CancellationError()) }
                // concurrency-allow: the race answers at the bound without awaiting this task; it is cancelled then.
                let job = Task { do { gate.finish(.success(try await work())) } catch { gate.finish(.failure(error)) } }
                // concurrency-allow: one-shot timer, cancelled when the work answers first.
                let timer = Task {
                    // wakeup-allow: one-shot deadline for a sandbox run (stops at the bound or the answer)
                    try? await Task.sleep(for: bound)
                    gate.finish(.failure(timeout()))
                }
                gate.onFinish { job.cancel(); timer.cancel() }
            }
        } onCancel: {
            gate.state.withLock { $0.cancelled = true }
            gate.finish(.failure(CancellationError()))
        }
    }

    private func onFinish(_ cancel: @escaping @Sendable () -> Void) {
        let finished = state.withLock { state -> Bool in
            if state.continuation == nil { return true }
            state.cancels.append(cancel)
            return false
        }
        if finished { cancel() }
    }

    /// The first answer wins; later ones are dropped.
    private func finish(_ result: Result<T, any Error>) {
        let taken = state.withLock { state -> (CheckedContinuation<T, any Error>, [@Sendable () -> Void])? in
            guard let continuation = state.continuation else { return nil }
            state.continuation = nil
            defer { state.cancels = [] }
            return (continuation, state.cancels)
        }
        guard let (continuation, cancels) = taken else { return }
        continuation.resume(with: result)
        for cancel in cancels { cancel() }
    }
}
