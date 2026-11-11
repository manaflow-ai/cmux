public import Foundation

/// `cmux cloud start-session` runs by what they ask for. Each caller waits for its run at most
/// its answer time, then answers `pending`, and the run goes on. The same ask again while a run
/// goes on waits for that run. A run that ends with a caller still waiting has reached it and is
/// dropped; one that ends after every caller answered `pending` is kept for the next same ask,
/// which gets its end once. A kept run lasts at most ``kept`` (checked on every ask) and at most
/// ``limit`` are kept, trimmed when a run starts and when one is kept; no timer. How long and how many,
/// and which kept runs go, are Rust's (`moves::wait`, ops `cloud_move_runs*`); this is the main-actor glue. Runs and
/// creations are per account (user and team): another account's ask never joins or takes them,
/// and a sign-out or team switch ends them (``forgetAll()``).
///
/// Generic over the run's answer (`Answer`, named ``Fields``) and the machine a creation makes, so it holds no App
/// type: the App names it `CloudStartSessionRuns`.
@MainActor
public final class CloudStartRuns<Answer: Sendable, Machine: Sendable> {
    public typealias Key = CloudStartRunKey
    /// What a run answers (the App's action result fields).
    public typealias Fields = Answer

    private struct Creation: Hashable {
        var name: String
        var account: [String?]
    }

    public typealias Outcome = Result<Fields, any Error>

    // A generic main-actor class: its isolated deinit crashes the Release optimizer (#23050).
    nonisolated deinit {}

    private final class Run {
        var task: Task<Outcome, Never>?
        /// Callers waiting for its end now: each is resumed when it ends, with the failure it
        /// gets if the run is forgotten first, or removes itself at its own deadline. An `early`
        /// one (the caller that started it) is also resumed when the run waits for the person.
        var waiters: [UUID: (end: AsyncStream<Outcome?>.Continuation, forgotten: any Error, early: Bool)] = [:]
        var outcome: Outcome?
        /// Forgotten (``forgetAll()``): a caller whose deadline fired first gets its `forgotten`
        /// failure all the same, never `pending`.
        var forgotten = false
        /// When it ended with nobody waiting (kept for the next same ask).
        var kept: ContinuousClock.Instant?

        nonisolated deinit {}
    }

    public static var kept: Duration { .milliseconds(CloudMoveCore.deadlines.runKeptMs) }
    public static var limit: Int { CloudMoveCore.deadlines.runsKept }
    private var runs: [Key: Run] = [:]
    /// Creations of a machine by name and account, each with its own token: two asks for one new
    /// name create one machine.
    private var creations: [Creation: (token: UUID, task: Task<Machine, any Error>)] = [:]
    /// Counts ``forgetAll()`` calls: a creation that ends after one is never handed out.
    private var forgets = 0
    /// Called when an ask joins a creation already going on (tests wait on it).
    public var joinedCreation: @MainActor (String) -> Void = { _ in }
    public var now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    /// The caller's wait: a one-shot sleep, cancelled when the run ends first.
    public var sleep: @MainActor (Duration) async -> Void = { duration in
        // wakeup-allow: one-shot answer deadline of one caller; cancelled when its run ends first
        try? await Task.sleep(for: duration)
    }

    /// The machine `create` makes for `name` in `account`, or the one a creation already going on
    /// for both makes. A creation the runs were forgotten during (``forgetAll()``) throws
    /// `CancellationError` even if it finished: cancellation is cooperative.
    public init() {}

    /// Whether a creation of a machine named `name` for `account` is going on now (`cloud start-session
    /// --name`): `cloud new-machine --name --environment` makes no second one beside it.
    public func isCreating(_ name: String, account: [String?]) -> Bool {
        creations[Creation(name: name, account: account)] != nil
    }

    public func creating(_ name: String, account: [String?], _ create: @escaping @MainActor () async throws -> Machine) async throws -> Machine {
        let key = Creation(name: name, account: account)
        let asked = forgets
        let unforgotten = { [self] (machine: Machine) throws -> Machine in
            guard forgets == asked else { throw CancellationError() }
            return machine
        }
        if let running = creations[key] {
            joinedCreation(name)
            return try unforgotten(await running.task.value)
        }
        let token = UUID()
        // task-owner: one creation per name and account; removed when it ends or by forgetAll().
        let task = Task<Machine, any Error> { @MainActor in try await create() }
        creations[key] = (token, task)
        defer { if creations[key]?.token == token { creations[key] = nil } }
        return try unforgotten(await task.value)
    }

    /// The end of `key`'s run, or `pending` once `within` has passed (the run goes on): a kept
    /// run's end (handed out once), the one going on, else `work`, started now. If the runs are
    /// forgotten while this caller waits (``forgetAll()``), it gets `forgotten`. With `early`, the
    /// caller that starts the run gets the run's ``asking(_:_:)`` answer as soon as the run waits
    /// for the person, instead of waiting in silence; the same ask again waits for the person.
    public func answer(_ key: Key, within: Duration, pending: Fields, forgotten: any Error, early: Bool = false,
                _ work: @escaping @MainActor () async throws -> Fields) async throws -> Fields {
        let (run, started) = take(key, work)
        if let outcome = run.outcome { return try outcome.get() }
        let caller = UUID()
        let (ends, continuation) = AsyncStream<Outcome?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        // The run's end resumes it (``take``), ``asking(_:_:)`` an early one, or ``forgetAll()``.
        run.waiters[caller] = (continuation, forgotten, early && started)
        // task-owner: this caller's answer deadline; cancelled below once the run ends first.
        let deadline = Task { @MainActor [sleep] in
            // wakeup-allow: one-shot answer deadline of one caller; cancelled when its run ends first
            await sleep(within)
            continuation.yield(nil)
        }
        defer {
            deadline.cancel()
            run.waiters[caller] = nil
            continuation.finish()
        }
        var ended: Outcome?
        for await value in ends {
            ended = value
            break
        }
        if let ended { return try ended.get() }
        // The stream keeps the first value: a forget or an end that came after the deadline did,
        // before this caller resumed, is read from the run. The forget wins (the run was cancelled);
        // an end reaches the caller instead of pending, and the run counts as seen (``take`` drops
        // it, since this caller was still registered when it ended).
        if run.forgotten { throw forgotten }
        if let outcome = run.outcome { return try outcome.get() }
        return pending
    }

    /// `key`'s run waits for the person (its card shows): the caller that started it with `early`
    /// gets `fields` now, and the run goes on.
    public func asking(_ key: Key, _ fields: Fields) {
        guard let run = runs[key], run.outcome == nil else { return }
        for (id, waiter) in run.waiters where waiter.early {
            waiter.end.yield(.success(fields))
            run.waiters[id] = nil
        }
    }

    /// The account the runs were asked in ended: each waiting caller gets its `forgotten`
    /// failure now, every run and creation is cancelled, and none is kept or joined after.
    public func forgetAll() {
        forgets += 1
        for run in runs.values {
            run.forgotten = true
            for waiter in run.waiters.values { waiter.end.yield(.failure(waiter.forgotten)) }
            run.waiters = [:]
            run.task?.cancel()
        }
        for creation in creations.values { creation.task.cancel() }
        runs = [:]
        creations = [:]
    }

    /// The run of `key` to answer, and whether it starts now: a kept one (taken out, its end
    /// handed out once), the one going on, else a new one.
    private func take(_ key: Key, _ work: @escaping @MainActor () async throws -> Fields) -> (Run, Bool) {
        if let run = runs[key] {
            if let kept = run.kept {
                runs[key] = nil
                if Self.reusable(age: now() - kept) { return (run, false) }
            } else {
                return (run, false)
            }
        }
        prune()
        let run = Run()
        runs[key] = run
        // task-owner: the start itself; it runs to its end even after its callers answered pending.
        run.task = Task { @MainActor [weak self] in
            let outcome: Outcome
            do { outcome = .success(try await work()) } catch { outcome = .failure(error) }
            run.outcome = outcome
            let reached = !run.waiters.isEmpty
            for waiter in run.waiters.values { waiter.end.yield(outcome) }
            if let self, runs[key] === run {
                if reached {
                    runs[key] = nil
                } else {
                    run.kept = now()
                    trim(keeping: Self.limit)
                }
            }
            return outcome
        }
        return (run, true)
    }

    /// Waits for `key`'s run to end (tests).
    public func settled(_ key: Key) async { _ = await runs[key]?.task?.value }

    public var count: Int { runs.count }
    public var keptCount: Int { runs.values.filter { $0.kept != nil }.count }
    /// Callers waiting on any run now (tests: a caller that answered pending holds nothing).
    public var waitingCount: Int { runs.values.reduce(0) { $0 + $1.waiters.count } }

    /// Whether a run kept `age` ago still answers the next same ask (Rust's rule; an FFI that does not answer starts anew).
    private static func reusable(age: Duration) -> Bool {
        CloudMoveCore().runReusable(ageMs: UInt64(max(0, age.wholeMilliseconds)))
    }

    /// Drops the kept runs Rust names: expired ones, then the oldest beyond `keeping`.
    private func trim(keeping: Int) {
        let at = now()
        let kept = Array(runs.compactMap { key, run in run.kept.map { (key, $0) } }.enumerated())
        let ages = kept.map { UInt64(max(0, (at - $0.element.1).wholeMilliseconds)) }
        // An FFI that does not answer drops every kept run: none outlives its limit.
        let drop = CloudMoveCore().runsToDrop(ages: ages, keeping: keeping) ?? kept.map(\.offset)
        for index in drop where kept.indices.contains(index) { runs[kept[index].element.0] = nil }
    }

    /// Before a new run: room for it among the kept ones.
    private func prune() { trim(keeping: Self.limit - 1) }
}

/// What a `cmux cloud start-session` run asks for (``CloudStartRuns``): the same key is the same run.
public struct CloudStartRunKey: Hashable, Sendable {
    /// `id:<machine id>` or `name:<machine name>`.
    public var machine: String
    public var agent: String
    public var cwd: String?
    /// The agent chat that asked; nil for a person's or a script's run.
    public var caller: String?
    /// The user and team signed in when it was asked (the App's `CloudService.account`).
    public var account: [String?]
    /// The run's `--login` word; nil for none. Runs that differ in it are different runs.
    public var login: String?
    /// The folder on this Mac the run copies (`--from-folder`); nil for none. Runs that differ in it are different runs.
    public var fromFolder: String?
    /// The run's `--model`; nil for none. Runs that differ in it are different runs.
    public var model: String?

    public init(machine: String, agent: String, cwd: String?, caller: String?, account: [String?], login: String? = nil, fromFolder: String? = nil, model: String? = nil) {
        (self.machine, self.agent, self.cwd, self.caller, self.account, self.login) = (machine, agent, cwd, caller, account, login)
        (self.fromFolder, self.model) = (fromFolder, model)
    }
}

/// Coalesces triggers waiting for the next read, without joining a read that
/// started before the trigger. Each caller waits for its own batch's result.
@MainActor
public final class CloudRefreshGate {
    @MainActor
    private final class Batch {
        var task: Task<Bool, Never>?
        var queued = true
        var waiters: Set<UUID> = []
    }

    private var tail: Batch?
    private var batches: [UUID: Batch] = [:]

    public init() {}

    @discardableResult
    public func run(_ operation: @escaping @MainActor () async -> Bool) async -> Bool {
        guard !Task.isCancelled else { return false }
        let batch: Batch
        if let tail, tail.queued, tail.task?.isCancelled == false {
            batch = tail
        } else {
            batch = Batch()
            let previous = tail?.task
            let batchID = UUID()
            batches[batchID] = batch
            tail = batch
            // task-owner: batches; cancel() stops every read during service teardown.
            batch.task = Task { @MainActor in
                defer {
                    self.batches.removeValue(forKey: batchID)
                    if self.tail === batch { self.tail = nil }
                }
                if let previous { _ = await previous.value }
                batch.queued = false
                guard !Task.isCancelled else { return false }
                return await operation()
            }
        }
        let ticket = UUID()
        batch.waiters.insert(ticket)
        guard let task = batch.task else { return false }
        defer { batch.waiters.remove(ticket) }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            // task-owner: one main-actor cancellation handoff; no recurring work.
            Task { @MainActor in
                batch.waiters.remove(ticket)
                if batch.waiters.isEmpty { batch.task?.cancel() }
            }
        }
        return !Task.isCancelled && result
    }

    /// Keeps the serialization chain until canceled work unwinds, so a restart
    /// cannot overlap an old transport that has not returned from cancellation.
    public func cancel() {
        for batch in batches.values { batch.task?.cancel() }
    }
}

extension CloudMoveCore {
    /// Whether a start-session run kept `ageMs` ago still answers the next same ask.
    func runReusable(ageMs: UInt64) -> Bool {
        struct Request: Encodable { var ageMs: UInt64 }
        struct Reply: Decodable { var reusable: Bool }
        return call("run_reusable", Request(ageMs: ageMs), as: Reply.self)?.reusable ?? false
    }

    /// The indexes of the kept runs (by their `ages`) to drop: expired ones, then the oldest beyond `keeping`.
    func runsToDrop(ages: [UInt64], keeping: Int) -> [Int]? {
        struct Kept: Encodable { var id: Int, ageMs: UInt64 }
        struct Request: Encodable { var kept: [Kept], keeping: Int }
        struct Reply: Decodable { var drop: [Int] }
        let request = Request(kept: ages.enumerated().map { Kept(id: $0.offset, ageMs: $0.element) }, keeping: keeping)
        return call("runs", request, as: Reply.self)?.drop
    }
}
