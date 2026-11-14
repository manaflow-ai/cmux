public import Foundation
import CmuxNextWakeups

/// The app's one waiter on each cloud task it handed off, whatever happens to the tab that sent it
/// (closed, reloaded) and across a relaunch. Its ``Source`` says what a task is: a sandboxed Run
/// (``Source/runs(wait:)``, `GET /api/runs/:id/wait`, held up to 10 s) or a hand-off (`GET
/// /v1/handoffs/:id/wait`, held up to 25 s). There is no push: each task gets one long-poll, and a
/// Run's send awaits that same wait (``follow(_:)``). When the Run ends, ``onEnd`` hears it once.
///
/// Every rule is Rust's (cmux-tui/crates/cmux-cloud-tasks `follower`, with its tests), asked over
/// the app FFI (`cloud_task_step`: the state, one event and the time in; the next state and the
/// effects out, in order). This class runs those effects: its poll tasks and their sleeps, the
/// waiters, the saved list in UserDefaults, ``onEnd`` and ``onForget``.
///
/// Stop conditions: each poll ends when its task is terminal, when the account that made it signs
/// out or another account signs in (``account(_:)``), when the server no longer shows it (403,
/// 404), or after the source's maximum age (Rust's answers). Cleanup: the poll tasks are cancelled
/// there and in ``stop()``; waiters still out are answered with an error, never left hanging.
@MainActor
public final class SandboxRunFollower {
    /// One wait call on Run `id` in `team`; answers the snapshot JSON.
    public typealias Wait = @Sendable (_ id: String, _ team: String?) async throws -> Data

    /// What the follower waits on: one wait call, which rules read it, and where its tasks are kept.
    public nonisolated struct Source: Sendable {
        /// The rules Rust applies: `runs` or `handoffs`.
        public enum Kind: String, Sendable, Encodable {
            case runs, handoffs
            /// The path a follow's error names (Rust's `Kind::path`).
            var path: String { self == .runs ? "/api/runs" : "/v1/handoffs" }
        }
        /// One wait on task `id` in `team`, past `cursor` (nil: from its start).
        public var wait: @Sendable (_ id: String, _ team: String?, _ cursor: Int?) async throws -> Data
        public var kind: Kind
        public var defaultsKey: String

        public init(wait: @escaping @Sendable (String, String?, Int?) async throws -> Data, kind: Kind, defaultsKey: String) {
            (self.wait, self.kind, self.defaultsKey) = (wait, kind, defaultsKey)
        }

        /// Sandboxed Runs (hq#3367).
        public static func runs(wait: @escaping Wait) -> Source {
            Source(wait: { id, team, _ in try await wait(id, team) }, kind: .runs, defaultsKey: SandboxRunFollower.defaultsKey)
        }
    }

    /// Where the Runs in flight are kept between launches.
    public nonisolated static let defaultsKey = "cmux.next.sandboxRuns.following"

    /// Ended tasks whose card was dropped after Rust's week: their banners go too.
    public var onForget: (@MainActor ([String]) -> Void)?
    /// A followed task ended or tells a notice (not a Run this app cancelled): once each.
    public var onEnd: (@MainActor (SandboxRunEnd) -> Void)?
    public let source: Source
    private let defaults: UserDefaults
    private let now: @MainActor () -> Date
    private let clock: any Clock<Duration>
    private var state = CloudTaskState()
    private var polls: [String: Task<Void, Never>] = [:]
    private var waiters: [String: [UUID: CheckedContinuation<Data, any Error>]] = [:]

    public convenience init(wait: @escaping Wait, defaults: UserDefaults = .standard, now: @escaping @MainActor () -> Date = { Date() },
                            clock: any Clock<Duration> = ContinuousClock()) {
        self.init(source: .runs(wait: wait), defaults: defaults, now: now, clock: clock)
    }

    public init(source: Source, defaults: UserDefaults = .standard, now: @escaping @MainActor () -> Date = { Date() },
                clock: any Clock<Duration> = ContinuousClock()) {
        (self.source, self.defaults, self.now, self.clock) = (source, defaults, now, clock)
        state = Wire.load(defaults.data(forKey: source.defaultsKey).map { String(decoding: $0, as: UTF8.self) })
    }

    /// The tasks in flight, oldest first.
    public var following: [SandboxRunRecord] { state.records }

    /// The task `id` that ended here, if it is still kept.
    public func endedRun(_ id: String) -> SandboxRunEnded? { state.ended.last { $0.record.id == id } }

    /// Whether a poll runs for `id` (tests).
    public func isPolling(_ id: String) -> Bool { polls[id] != nil }

    /// Whether task `id` is followed now or ended here (still kept).
    public func knows(_ id: String) -> Bool { state.records.contains { $0.id == id } || endedRun(id) != nil }

    /// The signed-in user (nil: none): Rust drops, resumes and replays the tasks for it.
    public func account(_ user: String?) { step(Event(on: "account", user: user)) }

    /// Follows the Run `record` names (just created by a send of this app) and answers its terminal
    /// snapshot. An error of a wait (or a 200 that is no Run snapshot) answers this call with
    /// `timedOut`, as the send's own poll did, while the follow goes on for the notification.
    public func follow(_ record: SandboxRunRecord) async throws -> Data {
        if let refused = step(Event(on: "follow", record: record))?.refused { throw Self.error(refused) }
        let token = UUID()
        let id = record.id
        let path = "\(source.kind.path)/\(id)"
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard polls[id] != nil, !Task.isCancelled else {
                    return continuation.resume(throwing: Task.isCancelled ? CancellationError() : CloudAPIError.timedOut(path))
                }
                waiters[id, default: [:]][token] = continuation
            }
        } onCancel: {
            // task-owner: one hop to answer this cancelled waiter; the poll goes on
            Task { @MainActor [weak self] in self?.answer(id, token: token, .failure(CancellationError())) }
        }
    }

    /// Follows task `record` without awaiting it (a hand-off found in the owner's list, or one this
    /// app just made); Rust leaves one of no signed-in user or of another.
    public func watch(_ record: SandboxRunRecord) { step(Event(on: "watch", record: record)) }

    /// Task `id`, followed now, changed at `changed` with its turn `running` or not, as the owner's list shows it.
    public func refresh(_ id: String, changed: Date, running: Bool) { step(Event(on: "refresh", id: id, changed: changed, running: running)) }

    /// The signed-in owner's list answered with `listed`: its incognito ids neither followed nor listed go (#31208).
    public func keepIncognito(listed: Set<String>) { step(Event(on: "keepIncognito", listed: listed.sorted())) }

    /// This app asked the server to cancel Run `id` (the person's own action): it ends silently.
    public func noteCancel(_ id: String) { step(Event(on: "noteCancel", id: id)) }

    /// The end of task `id` was told (its banner posted, found delivered, or held back by the settings).
    public func markTold(_ id: String) { step(Event(on: "markTold", id: id)) }

    /// Drops the ended tasks older than Rust's week and tells ``onForget`` (also at a banner's click).
    public func forgetOld() { step(Event(on: "forgetOld")) }

    /// Ends every poll (the app quits); the saved tasks stay for the next launch.
    public func stop() {
        for id in Array(polls.keys) { endPoll(id, error: CancellationError()) }
    }

    private func start(_ id: String) {
        guard polls[id] == nil else { return }
        let (wait, clock) = (source.wait, clock)
        polls[id] = Task { [weak self] in // task-owner: in polls; cancelled when the task ends, on sign-out and in stop()
            var backoff = Backoff(initial: .seconds(2), maximum: .seconds(60))
            // When the server last answered this poll readably (Rust's running-and-heard age rule).
            var heard = self?.now() ?? Date()
            // wakeup-allow: a long-poll, each pass one /wait call the server holds (10 s for a Run, 25 s for a hand-off); a failure waits a Backoff delay
            while !Task.isCancelled {
                guard let self else { return }
                guard let polled = self.step(Event(on: "poll", id: id, heard: heard)) else { return self.rulesFailed(id) }
                guard let next = polled.wait else { return }
                let began = ContinuousClock.now
                var answer = Event(on: "answer", id: id)
                var data = Data()
                do {
                    data = try await wait(id, next.team, next.cursor)
                    answer.body = String(decoding: data, as: UTF8.self)
                } catch is CancellationError {
                    return
                } catch CloudAPIError.http(let status, _, _, _, _) {
                    answer.status = status
                    answer.failed = true
                } catch {
                    answer.failed = true
                }
                answer.cancelled = Task.isCancelled
                guard let reply = self.step(answer, answer: data) else { return self.rulesFailed(id) }
                if reply.heard == true { heard = self.now() }
                switch reply.next {
                case "again":
                    backoff.reset()
                    // A server that answers at once (no long-poll) is asked again no sooner than every 2 s.
                    // wakeup-allow: spacing of the long-poll above, only when the server did not hold the call
                    if ContinuousClock.now - began < .seconds(2) { do { try await clock.sleep(for: .seconds(2)) } catch { return } }
                case "backoff":
                    // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
                    do { try await backoff.wait(owner: "sandboxRuns.follow", clock: clock) } catch { return }
                default:
                    return
                }
            }
        }
    }

    /// Asks Rust what `event` does now, keeps its state and runs its effects in order; `answer` is
    /// the wait's body an effect answers or tells with. Nil when the FFI does not answer.
    @discardableResult
    private func step(_ event: Event, answer: Data = Data()) -> Reply? {
        guard let reply = Wire.step(source.kind, now: now(), state: state, event: event) else { return nil }
        state = reply.state
        for effect in reply.effects { run(effect, answer: answer) }
        return reply
    }

    private func run(_ effect: Effect, answer: Data) {
        let id = effect.id ?? ""
        switch effect.action {
        case "save": save()
        case "start": start(id)
        case "endPoll": endPoll(id, error: effect.error.map(Self.error) ?? CancellationError())
        case "clearPoll": polls.removeValue(forKey: id)
        case "answer": answerAll(id, effect.error.map { .failure(Self.error($0)) } ?? .success(answer))
        case "tell":
            guard let record = effect.record, let outcome = effect.outcome else { return }
            let replayed = effect.replayed == true
            onEnd?(SandboxRunEnd(record: record, outcome: outcome, snapshot: replayed ? effect.card ?? Data() : answer, replayed: replayed))
            if effect.markTold == true { markTold(record.id) }
        case "forget": onForget?(effect.ids ?? [])
        default: break
        }
    }

    /// The rules gave no answer (an FFI failure): the poll ends and its waiters get an error, so no
    /// send hangs on a poll nothing drives.
    private func rulesFailed(_ id: String) {
        endPoll(id, error: CloudAPIError.decoding("the cloud task rules did not answer"))
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

    /// Writes the saved list of the state as it is now (Rust leaves incognito tasks out).
    private func save() {
        guard let saved = Wire.saved(state) else { return }
        defaults.set(Data(saved.utf8), forKey: source.defaultsKey)
    }

    private static func error(_ failure: Failure) -> any Error {
        failure.kind == "notSignedIn" ? CloudAPIError.notSignedIn : CloudAPIError.timedOut(failure.path ?? "")
    }

    // MARK: The FFI's words (cmux-cloud-tasks `follower`)

    /// The three calls of the app FFI (`cloud_task_load`, `cloud_task_step`, `cloud_task_saved`).
    private nonisolated struct Wire {
        private struct Load: Encodable { var saved: String? }
        private struct Loaded: Decodable { var state: CloudTaskState }
        private struct Step: Encodable { var source: Source.Kind, now: Date, state: CloudTaskState, event: Event }
        private struct State: Encodable { var state: CloudTaskState }
        private struct Saved: Decodable { var saved: String }

        /// A launch's state from the saved list; an FFI that does not answer starts empty.
        static func load(_ saved: String?) -> CloudTaskState {
            CloudStartCore().call("cloud_task_load", Load(saved: saved), as: Loaded.self)?.state ?? CloudTaskState()
        }

        static func step(_ kind: Source.Kind, now: Date, state: CloudTaskState, event: Event) -> Reply? {
            CloudStartCore().call("cloud_task_step", Step(source: kind, now: now, state: state, event: event), as: Reply.self)
        }

        /// The saved list of `state`; nil when the FFI does not answer (the last one stays).
        static func saved(_ state: CloudTaskState) -> String? {
            CloudStartCore().call("cloud_task_saved", State(state: state), as: Saved.self)?.saved
        }
    }

    /// One event as Rust reads it (`on` names it; the fields it does not take are left out).
    private nonisolated struct Event: Encodable {
        var on: String
        var user: String?
        var record: SandboxRunRecord?
        var id: String?
        var changed: Date?
        var running: Bool?
        var listed: [String]?
        var heard: Date?
        var body: String?
        var status: Int?
        var failed: Bool?
        var cancelled: Bool?
    }

    private nonisolated struct Failure: Decodable { var kind: String, path: String? }

    private nonisolated struct Effect: Decodable {
        /// What to do (`save`, `start`, `endPoll`, `clearPoll`, `answer`, `tell`, `forget`).
        var action: String
        var id: String?
        var error: Failure?
        var record: SandboxRunRecord?
        var outcome: SandboxRunEnd.Outcome?
        var replayed: Bool?
        var card: Data?
        var markTold: Bool?
        var ids: [String]?

        private enum CodingKeys: String, CodingKey { case action = "do", id, error, record, outcome, replayed, card, markTold, ids }
    }

    private nonisolated struct Reply: Decodable {
        struct Wait: Decodable { var cursor: Int?, team: String? }
        var state: CloudTaskState
        var effects: [Effect]
        var refused: Failure?
        var wait: Wait?
        var next: String?
        var heard: Bool?
    }
}

/// The follower's state as Rust keeps it between calls (cmux-cloud-tasks `model::State`): dates as
/// `JSONEncoder` writes them, a card as base64.
nonisolated struct CloudTaskState: Codable, Sendable {
    var records: [SandboxRunRecord] = []
    var ended: [SandboxRunEnded] = []
    var cancelled: [String] = []
    var incognito: [String] = []
    var incognitoOwners: [String: String] = [:]
    var user: String?
}
