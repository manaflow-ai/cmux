public import Foundation
import CmuxNextWakeups

/// A sandboxed Run this app handed off (hq#3367), as the follower keeps it across a relaunch.
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

    public init(id: String, task: String, key: String, user: String, team: String?, started: Date) {
        (self.id, self.task, self.key, self.user, self.team, self.started) = (id, task, key, user, team, started)
    }
}

/// How a followed Run ended.
public nonisolated struct SandboxRunEnd: Sendable {
    public enum Outcome: String, Sendable { case succeeded, failed, timedOut, cancelled }
    public var record: SandboxRunRecord
    public var outcome: Outcome
    /// The terminal snapshot (`{run, attempts, artifacts, receipt}`) as the server sent it.
    public var snapshot: Data
}

/// The app's one waiter on each sandboxed Run it handed off, whatever happens to the tab that sent
/// it (closed, reloaded) and across a relaunch. Each Run gets one long-poll of `GET /api/runs/:id/wait`
/// (the server holds a call up to 10 s; there is no push), and the tab's send awaits that same wait
/// (``follow(_:)``). When the Run ends, ``onEnd`` hears it once: the record is dropped from the saved
/// list before ``onEnd`` runs, so neither a second answer nor a relaunch can tell it again. A Run this
/// app cancelled (``noteCancel(_:)``) ends without ``onEnd``.
///
/// Stop conditions: each Run's poll ends when the Run is terminal, when the account that made it
/// signs out or another account signs in (``account(_:)``), when the server no longer shows it
/// (403, 404), or after ``maximumAge``. Cleanup: the poll tasks are cancelled there and in ``stop()``;
/// waiters still out are answered with an error, never left hanging.
@MainActor
public final class SandboxRunFollower {
    /// One wait call on Run `id` in `team`; answers the snapshot JSON.
    public typealias Wait = @Sendable (_ id: String, _ team: String?) async throws -> Data

    /// Where the Runs in flight are kept between launches.
    public static let defaultsKey = "cmux.next.sandboxRuns.following"
    /// At most this many Runs are followed; the oldest goes first.
    public static let limit = 32
    /// A Run not terminal after this long is given up (the server caps a task at 12 minutes).
    public static let maximumAge: TimeInterval = 6 * 3_600

    /// A followed Run ended (not one this app cancelled): once per Run.
    public var onEnd: (@MainActor (SandboxRunEnd) -> Void)?
    private let wait: Wait
    private let defaults: UserDefaults
    private let now: @MainActor () -> Date
    private let clock: any Clock<Duration>
    private var records: [String: SandboxRunRecord] = [:]
    /// Runs that ended here, newest last (bounded): a late ``follow(_:)`` of one never tells it again.
    private var ended: [String] = []
    private var polls: [String: Task<Void, Never>] = [:]
    private var waiters: [String: [UUID: CheckedContinuation<Data, any Error>]] = [:]
    private var cancelledHere: Set<String> = []
    private var user: String?

    public init(wait: @escaping Wait, defaults: UserDefaults = .standard, now: @escaping @MainActor () -> Date = { Date() },
                clock: any Clock<Duration> = ContinuousClock()) {
        self.wait = wait
        self.defaults = defaults
        self.now = now
        self.clock = clock
        if let data = defaults.data(forKey: Self.defaultsKey), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            records = Dictionary(saved.following.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            ended = saved.ended
        }
    }

    /// The Runs in flight, oldest first.
    public var following: [SandboxRunRecord] { records.values.sorted { $0.started < $1.started } }

    /// Whether a poll runs for `id` (tests).
    public func isPolling(_ id: String) -> Bool { polls[id] != nil }

    /// The signed-in user (nil: none). A sign-out after a sign-in drops every Run; a user signing
    /// in resumes that user's Runs and drops the others (another account can't read them). The
    /// launch's first nil (the session still loading) keeps the saved Runs for their user.
    public func account(_ user: String?) {
        guard user != self.user else { return }
        let signedOut = user == nil && self.user != nil
        self.user = user
        for record in records.values where signedOut || (user != nil && record.user != user) {
            drop(record.id, error: CloudAPIError.notSignedIn)
        }
        guard user != nil else { return }
        for record in following { start(record) }
    }

    /// Follows the Run `record` names (just created by a send of this app) and answers its terminal
    /// snapshot. An error of a wait (or a 200 that is no Run snapshot) answers this call with
    /// `timedOut`, as the send's own poll did, while the follow goes on for the notification.
    public func follow(_ record: SandboxRunRecord) async throws -> Data {
        if records[record.id] == nil, !ended.contains(record.id) {
            records[record.id] = record
            trim()
            save()
        }
        start(record)
        let token = UUID()
        let id = record.id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard polls[id] != nil, !Task.isCancelled else {
                    return continuation.resume(throwing: Task.isCancelled ? CancellationError() : CloudAPIError.timedOut("/api/runs/\(id)"))
                }
                waiters[id, default: [:]][token] = continuation
            }
        } onCancel: {
            // task-owner: one hop to answer this cancelled waiter; the poll goes on
            Task { @MainActor [weak self] in self?.answer(id, token: token, .failure(CancellationError())) }
        }
    }

    /// This app asked the server to cancel Run `id` (the person's own action): it ends silently.
    public func noteCancel(_ id: String) {
        if records[id] != nil { cancelledHere.insert(id) }
    }

    /// Ends every poll (the app quits); the saved Runs stay for the next launch.
    public func stop() {
        for id in Array(polls.keys) { endPoll(id, error: CancellationError()) }
    }

    private func start(_ record: SandboxRunRecord) {
        let id = record.id
        guard polls[id] == nil, records[id] != nil else { return }
        let (wait, clock) = (wait, clock)
        polls[id] = Task { [weak self] in // task-owner: in polls; cancelled when the Run ends, on sign-out and in stop()
            var backoff = Backoff(initial: .seconds(2), maximum: .seconds(60))
            // wakeup-allow: a long-poll, each pass one /wait call the server holds up to 10 s; a failure waits a Backoff delay
            while !Task.isCancelled {
                guard let self, self.records[id] != nil else { return }
                guard self.now().timeIntervalSince(record.started) < Self.maximumAge else {
                    return self.drop(id, error: CloudAPIError.timedOut("/api/runs/\(id)"))
                }
                let began = ContinuousClock.now
                let read: Read
                do {
                    read = Self.read(try await wait(id, record.team))
                } catch is CancellationError {
                    return
                } catch CloudAPIError.http(let status, _, _, _, _) where status == 403 || status == 404 {
                    // The server doesn't show this Run to this account any more: nothing to wait for.
                    return self.drop(id, error: CloudAPIError.timedOut("/api/runs/\(id)"))
                } catch {
                    read = .unreadable
                }
                switch read {
                case .ended(let outcome, let data):
                    return self.end(id, outcome: outcome, snapshot: data)
                case .running:
                    backoff.reset()
                    // A server that answers at once (no long-poll) is asked again no sooner than every 2 s.
                    // wakeup-allow: spacing of the long-poll above, only when the server did not hold the call
                    if ContinuousClock.now - began < .seconds(2) { do { try await clock.sleep(for: .seconds(2)) } catch { return } }
                case .unreadable:
                    self.answerAll(id, .failure(CloudAPIError.timedOut("/api/runs/\(id)")))
                    // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
                    do { try await backoff.wait(owner: "sandboxRuns.follow", clock: clock) } catch { return }
                }
            }
        }
    }

    private func end(_ id: String, outcome: SandboxRunEnd.Outcome, snapshot: Data) {
        guard let record = records.removeValue(forKey: id) else { return }
        ended.append(id)
        if ended.count > Self.limit { ended.removeFirst(ended.count - Self.limit) }
        save()
        polls.removeValue(forKey: id)
        answerAll(id, .success(snapshot))
        let silent = cancelledHere.remove(id) != nil && outcome == .cancelled
        if !silent { onEnd?(SandboxRunEnd(record: record, outcome: outcome, snapshot: snapshot)) }
    }

    /// Stops following `id` without telling it.
    private func drop(_ id: String, error: any Error) {
        records[id] = nil
        cancelledHere.remove(id)
        save()
        endPoll(id, error: error)
    }

    private func endPoll(_ id: String, error: any Error) {
        polls.removeValue(forKey: id)?.cancel()
        answerAll(id, .failure(error))
    }

    private func answerAll(_ id: String, _ result: Result<Data, any Error>) {
        for continuation in (waiters.removeValue(forKey: id) ?? [:]).values { continuation.resume(with: result) }
    }

    private func answer(_ id: String, token: UUID, _ result: Result<Data, any Error>) {
        waiters[id]?.removeValue(forKey: token)?.resume(with: result)
    }

    private func trim() {
        for record in following.dropLast(Self.limit) { drop(record.id, error: CloudAPIError.timedOut("/api/runs/\(record.id)")) }
    }

    private func save() {
        let saved = Saved(following: following, ended: ended)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    private nonisolated struct Saved: Codable {
        var following: [SandboxRunRecord]
        var ended: [String]
    }

    nonisolated enum Read {
        case running
        case ended(SandboxRunEnd.Outcome, Data)
        case unreadable
    }

    /// One wait's answer: terminal once the snapshot carries its receipt or a terminal status.
    nonisolated static func read(_ data: Data) -> Read {
        guard let snapshot = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let run = snapshot["run"] as? [String: Any] else { return .unreadable }
        let receipt = snapshot["receipt"] as? [String: Any]
        let status = receipt?["status"] as? String ?? run["status"] as? String
        guard receipt != nil || ["succeeded", "failed", "cancelled"].contains(status) else { return .running }
        switch status {
        case "succeeded": return .ended(.succeeded, data)
        case "cancelled": return .ended(.cancelled, data)
        default: return .ended(receipt?["timedOut"] as? Bool == true ? .timedOut : .failed, data)
        }
    }
}
