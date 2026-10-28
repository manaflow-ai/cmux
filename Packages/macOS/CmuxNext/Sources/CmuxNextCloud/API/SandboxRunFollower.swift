public import Foundation
import CmuxNextWakeups

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
    /// A Run not terminal after this long is given up (the server caps a task at 12 minutes), so the
    /// Runs in flight need no count limit.
    public static let maximumAge: TimeInterval = 6 * 3_600
    /// How long an ended Run's card is kept for its banner (its banner is withdrawn with it).
    public static let keptEnded: TimeInterval = 7 * 86_400
    /// The cancels this app sent that are kept for Runs still in flight.
    public static let cancelLimit = 256

    /// Ended Runs whose card was dropped after ``keptEnded``: their banners go too.
    public var onForget: (@MainActor ([String]) -> Void)?

    /// A followed Run ended (not one this app cancelled): once per Run.
    public var onEnd: (@MainActor (SandboxRunEnd) -> Void)?
    private let wait: Wait
    private let defaults: UserDefaults
    private let now: @MainActor () -> Date
    private let clock: any Clock<Duration>
    private var records: [String: SandboxRunRecord] = [:]
    /// Runs that ended here, newest last, for ``keptEnded``: a late ``follow(_:)`` of one never tells it again.
    private var ended: [SandboxRunEnded] = []
    private var polls: [String: Task<Void, Never>] = [:]
    private var waiters: [String: [UUID: CheckedContinuation<Data, any Error>]] = [:]
    /// Runs this app asked to cancel, newest last (bounded), noted before or after their follow
    /// starts: a cancel that races the send's hand-off still ends silently.
    private var cancelledHere: [String] = []
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
            cancelledHere = saved.cancelled ?? []
        }
    }

    /// The Runs in flight, oldest first.
    public var following: [SandboxRunRecord] { records.values.sorted { $0.started < $1.started } }

    /// The Run `id` that ended here, if it is still kept.
    public func endedRun(_ id: String) -> SandboxRunEnded? { ended.last { $0.record.id == id } }

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
        guard let user else { return }
        prune()
        tellUntold(of: user)
        for record in following { start(record) }
    }

    /// Follows the Run `record` names (just created by a send of this app) and answers its terminal
    /// snapshot. An error of a wait (or a 200 that is no Run snapshot) answers this call with
    /// `timedOut`, as the send's own poll did, while the follow goes on for the notification.
    public func follow(_ record: SandboxRunRecord) async throws -> Data {
        // Another account signed in since the create: its session can't read this Run, and must not hear of it.
        if let user, record.user != user { throw CloudAPIError.timedOut("/api/runs/\(record.id)") }
        if records[record.id] == nil, endedRun(record.id) == nil {
            records[record.id] = record
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

    /// This app asked the server to cancel Run `id` (the person's own action): it ends silently, also
    /// when the note comes before the Run's follow, or the app quits before the end.
    public func noteCancel(_ id: String) {
        guard !cancelledHere.contains(id) else { return }
        cancelledHere.append(id)
        if cancelledHere.count > Self.cancelLimit { cancelledHere.removeFirst(cancelledHere.count - Self.cancelLimit) }
        save()
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
        let silent = cancelledHere.contains(id) && outcome == .cancelled
        cancelledHere.removeAll { $0 == id }
        // Saved untold first: a crash before the banner leaves it to the next launch, never lost;
        // marked told once ``onEnd`` ran, so it is never told twice.
        ended.append(SandboxRunEnded(record: record, outcome: outcome, card: Self.card(snapshot), at: now(), told: silent))
        prune()
        save()
        polls.removeValue(forKey: id)
        answerAll(id, .success(snapshot))
        if !silent { tell(id, SandboxRunEnd(record: record, outcome: outcome, snapshot: snapshot)) }
    }

    /// Runs ``onEnd`` for ended Run `id`, then marks it told. A replayed end is marked by its
    /// listener (``markTold(_:)``) once its banner is handled: that may take a moment (a read of the
    /// delivered banners), and a quit inside it must leave the end to the next launch.
    private func tell(_ id: String, _ end: SandboxRunEnd) {
        onEnd?(end)
        if !end.replayed { markTold(id) }
    }

    /// The end of Run `id` was told (its banner posted, found delivered, or held back by the settings).
    public func markTold(_ id: String) {
        guard let index = ended.lastIndex(where: { $0.record.id == id }), !ended[index].told else { return }
        ended[index].told = true
        save()
    }

    /// Tells the ends of `user`'s Runs that were saved but not told (the app quit or crashed between the two).
    private func tellUntold(of user: String) {
        for run in ended where !run.told && run.record.user == user {
            tell(run.record.id, SandboxRunEnd(record: run.record, outcome: run.outcome, snapshot: run.card ?? Data(), replayed: true))
        }
    }

    /// Drops the ended Runs older than ``keptEnded`` and tells ``onForget`` (also at a banner's click).
    public func forgetOld() { prune() }

    /// Drops the ended Runs older than ``keptEnded`` and tells ``onForget``.
    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.keptEnded)
        let old = ended.filter { $0.at < cutoff }.map(\.record.id)
        guard !old.isEmpty else { return }
        ended.removeAll { $0.at < cutoff }
        onForget?(old)
    }

    /// Stops following `id` without telling it.
    private func drop(_ id: String, error: any Error) {
        records[id] = nil
        cancelledHere.removeAll { $0 == id }
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

    private func save() {
        let saved = Saved(following: following, ended: ended, cancelled: cancelledHere)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    private nonisolated struct Saved: Codable {
        var following: [SandboxRunRecord]
        var ended: [SandboxRunEnded]
        /// Runs this app asked to cancel (``noteCancel(_:)``): a quit before their end keeps them silent.
        var cancelled: [String]?
    }

    /// The part of a final snapshot the Run's card needs: its receipt.
    nonisolated static func card(_ snapshot: Data) -> Data? {
        guard let object = (try? JSONSerialization.jsonObject(with: snapshot)) as? [String: Any],
              let receipt = object["receipt"] as? [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["receipt": receipt])
    }

    nonisolated enum Read {
        case running
        case ended(SandboxRunEnd.Outcome, Data)
        case unreadable
    }

    /// One wait's answer. A sandboxed Run is terminal once its snapshot carries its receipt (the
    /// server writes it with the terminal status); until then it runs. A body that is no Run snapshot,
    /// or names a status the Run API has not, is unreadable, never an end.
    nonisolated static func read(_ data: Data) -> Read {
        let statuses: Set<String> = ["queued", "running", "cancelling", "succeeded", "failed", "cancelled"]
        guard let snapshot = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let run = snapshot["run"] as? [String: Any], let status = run["status"] as? String,
              statuses.contains(status) else { return .unreadable }
        guard let receiptValue = snapshot["receipt"], !(receiptValue is NSNull) else { return .running }
        guard let receipt = receiptValue as? [String: Any], let ending = receipt["status"] as? String else { return .unreadable }
        switch ending {
        case "succeeded": return .ended(.succeeded, data)
        case "cancelled": return .ended(.cancelled, data)
        case "failed": return .ended(receipt["timedOut"] as? Bool == true ? .timedOut : .failed, data)
        default: return .unreadable
        }
    }
}
