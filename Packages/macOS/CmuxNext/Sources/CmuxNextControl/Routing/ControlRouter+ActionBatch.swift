import CmuxNextActions
public import CmuxNextSettings
import Foundation
import CmuxNextCompat
public import CmuxNextWakeups

/// `action.batch`: many app actions in one request (CLAUDE.md "Go past Chrome where cmux is
/// scripted": a burst of scripted changes is one request, and it never stands between the person's
/// input and its frame).
///
/// Params: `ops`, an array of `action.run` param objects (`action` or `cli_name` with `cli`,
/// `target`, `args`, `focus`, `background`, `origin`); and for the whole batch `wait` (default
/// true), `idempotency_key`, `after` (read barrier) and `caller`. Any other batch-level member
/// (an op's `origin` or `target` put there) is `invalid_params`, `not_run`.
///
/// - Every op is resolved and validated off the main actor before any runs. One invalid op
///   refuses the whole batch: `not_run`, with `data.op` its index.
/// - The ops run in order, in slices: each slice is one automation task of the main-thread
///   scheduler and runs ops while ``MainFrameBudget`` lets the automation class run (at least one
///   op), so a slice never holds the main thread past the class's per-frame budget plus one op, and
///   a person's pending key or click is dispatched between two slices, before the rest of the batch.
///   No op count is tuned: a long batch only takes more frames.
/// - When the executor stages changes (``ControlActionExecutor/stageChanges(scope:until:)``), the stage opens
///   before the first slice and commits after the last one (or where the batch ended), so what it
///   holds back shows once, not slice by slice.
/// - Not all-or-nothing: a handler that refuses at run time stops the batch there. The ops before
///   it stay applied (`data.applied` counts them), the rest never run. The same holds for a later
///   slice that never ran (its deadline passed in the queue, the queue was full): that answer is
///   never `not_run`. The daemon work an op started (a rename, a close) fails after the ops after
///   it ran, so it does not stop them: the answer names the first op whose work failed (`data.op`,
///   with its own action), every such op (`data.failed`) and how many ops ran (`data.applied`); an
///   earlier failure answers before a later refusal.
/// - With `wait`, the reply comes after every daemon command of every op replied and a snapshot
///   reflects them (as `action.run`).
///
/// Targets name objects that exist when the request arrives: an op cannot name what an earlier
/// op of the same batch creates.
extension ControlRouter {
    func runBatch(_ call: ControlCall) async throws -> JSONValue {
        do {
            return try await startBatch(call)
        } catch let error as ControlError where !call.progress.hasStarted && error.code != "timeout" {
            // Refused before any handler ran: nothing applied.
            throw error.notRun()
        }
    }

    private func startBatch(_ call: ControlCall) async throws -> JSONValue {
        // An op's member at the batch level (`origin`, `target`, `focus`) is refused, as `action.run`
        // refuses an unknown argument: ignored, every op would run with its default.
        if let unknown = call.params.keys.sorted().first(where: { $0 != "ops" && !Self.batchLevelMembers.contains($0) }) {
            throw ControlError.invalidParams(ControlStrings.format("control.error.unknownParam", "%1$@ does not take params.%2$@", call.method, unknown))
        }
        let ops = try Self.batchOps(call.params)
        let catalog = call.snapshot.catalog
        let caller = try ControlCaller(call.params)
        var given: [(action: ControlActionInfo, request: ControlActionRequest)] = []
        given.reserveCapacity(ops.count)
        for (index, op) in ops.enumerated() {
            do {
                let action = try Self.resolveAction(op, in: catalog)
                given.append((action, try Self.validated(action, params: op, call: call, caller: caller)))
            } catch let error as ControlError {
                throw error.atBatchOp(index)
            }
        }
        let key = try Self.idempotencyKey(call.params)
        return try await keyed(key, fingerprint: .batch(given.map(\.request)), call: call) {
            try await self.executeBatch(given, key: key, call: call)
        }
    }

    /// `params.ops`: each op an object without the batch-level members.
    static func batchOps(_ params: [String: JSONValue]) throws -> [[String: JSONValue]] {
        guard case .array(let items)? = params["ops"], !items.isEmpty else {
            throw ControlError.invalidParams(ControlStrings.text("control.error.batchOpsShape", "params.ops must be a non-empty array of action.run params"))
        }
        return try items.enumerated().map { index, item in
            guard case .object(let op) = item else {
                throw ControlError.invalidParams(ControlStrings.text("control.error.batchOpsShape", "params.ops must be a non-empty array of action.run params"))
                    .atBatchOp(index)
            }
            for member in batchLevelMembers where op.index(forKey: member) != nil {
                throw ControlError.invalidParams(ControlStrings.format("control.error.batchMemberPerOp",
                                                                       "%@ applies to the whole action.batch, not to one op", member))
                    .atBatchOp(index)
            }
            return op
        }
    }

    /// The actions a batch's ops name (the ones that resolve), for its deadline and limit.
    static func batchActions(_ params: [String: JSONValue], in catalog: ControlCatalog) -> [ControlActionInfo] {
        guard case .array(let items)? = params["ops"] else { return [] }
        return items.compactMap { item in item.objectValue.flatMap { try? resolveAction($0, in: catalog) } }
    }

    /// Members that apply to the whole batch: an op that carries one is refused.
    static let batchLevelMembers = ["wait", "idempotency_key", "after", "caller"]

    private func executeBatch(_ given: [(action: ControlActionInfo, request: ControlActionRequest)], key: String?,
                              call: ControlCall) async throws -> JSONValue {
        var requests: [ControlActionRequest] = []
        requests.reserveCapacity(given.count)
        for (index, op) in given.enumerated() {
            do {
                requests.append(try await prepared(op.action, op.request, call: call))
            } catch let error as ControlError {
                throw error.atBatchOp(index)
            }
        }
        let executor = self.executor
        let progress = call.progress
        let wait = call.params["wait"]?.boolValue ?? true
        let scope = progress.track(ControlCommandScope(idempotencyKey: key))
        let expired = ControlError.timeout(call.method, after: max(call.deadline - .now, .zero))
        var runs: [ControlActionRun] = []
        runs.reserveCapacity(requests.count)
        let frames = frameSource
        let sliceLimit = workQueue.limits.frameBudget
        // Why a later slice never ran, when earlier ones applied.
        var cutShort: ControlError?
        // The batch's changes show once, when its last slice ran (or it ended early).
        // Mutex: set once inside the queue's synchronous main-actor work closure and read after it; no actor hop fits there.
        let stage = Mutex<(@MainActor @Sendable () -> Void)?>(nil)
        do {
            while runs.count < requests.count {
                let remaining = Array(requests.dropFirst(runs.count))
                let ran = try await workQueue.run(connection: call.connection, method: call.method, deadline: call.deadline,
                                                  countingFrom: call.engineStartMark) { () throws -> [ControlActionRun] in
                    // The request may have answered `not_run` already: then never run.
                    guard progress.begin(), scope.noting("handler") else { throw expired }
                    if stage.withLock({ $0 == nil }) {
                        let commit = executor.stageChanges(scope: scope, until: call.deadline)
                        stage.withLock { $0 = commit }
                    }
                    // The queue runs this from a run-loop block, where no task is current (cx-bpcj).
                    return ControlCommandScope.$current.withValueInTask(scope) {
                        Self.batchSlice(remaining, executor: executor, budget: frames.mainFrameBudget, limit: sliceLimit)
                    }
                }
                runs += ran
                guard ran.last.map({ if case .ran = $0.outcome { true } else { false } }) ?? false else { break }
            }
        } catch let error as ControlError where !runs.isEmpty {
            // A later slice never ran (its deadline passed in the queue, the queue was full) after
            // earlier ones applied: the batch ends there, as at a refusal. Its answer says how many
            // ops applied and that the request did run (never `not_run`, which a client reads as
            // safe to send again: the applied ops would run twice).
            cutShort = error.atBatchOp(runs.count, applied: runs.count).ranInPart()
        }
        if let commit = stage.withLock({ $0 }) { await MainActor.run { commit() } }
        // The last run is the refused one when the batch stopped early.
        let refused = zip(given, runs).enumerated().reversed().first.flatMap { index, pair -> (index: Int, action: String, error: ControlError)? in
            guard let error = ControlError.actionOutcome(pair.1.outcome, action: pair.0.action.id) else { return nil }
            return (index, pair.0.action.id, error)
        }
        // Ops `0..<applied` ran and were not refused; from `applied` on, none applied.
        let applied = refused?.index ?? runs.count
        // `op` below indexes `opWork` (one entry per run), a prefix of `given`, so it always names an op.
        let actionIDs = given.map(\.action.id)
        let opWork = runs.map(\.work)
        let results = runs.flatMap(\.results)
        let refusal: (index: Int, action: String, failure: ControlError)? = refused.map { refused in
            // A refusal that started no work applied nothing.
            var failure = refused.error.atBatchOp(refused.index, applied: applied)
            if applied == 0, opWork.allSatisfy(\.isEmpty) { failure = failure.notRun() }
            return (refused.index, refused.action, failure)
        }
        let ending: (failure: ControlError, action: String)? = refusal.map { (failure: $0.failure, action: $0.action) }
            ?? cutShort.map { (failure: $0, action: "action.batch") }
        let reply: [String: JSONValue] = [
            "ran": JSONValue(applied),
            "waited": .bool(wait),
            "ops": .array(zip(given, requests).map { op, request in
                ["action": .string(op.action.id), "args": .object(request.arguments.mapValues(\.json))]
            }),
            "idempotency_key": .optional(key),
        ]
        let settleDeadline = max(call.deadline, .now + Self.settleLimit)
        let method = call.method
        // Unstructured on purpose (as `action.run`): a request that times out or does not wait
        // answers while the batch keeps settling; the key stays pending until it settled. Every
        // ending takes this one path: a batch that stopped early (a refusal, a later transaction
        // that never ran) settles the ops that applied, closes its command scope, and only then
        // records its answer under the key.
        let settling = Task { [self] () -> ControlIdempotencyCache.Outcome in
            let settled = await settle(opWork: opWork, scope: scope, action: ending?.action ?? "action.batch", method: method,
                                       deadline: settleDeadline, replyBy: { call.movedDeadline })
            // The earliest op that failed answers. An op's work fails after the ops after it ran
            // (it does not stop them), so its answer names the op (`data.op`), every op whose work
            // failed (`data.failed`) and how many ops ran (`data.applied`).
            let outcome: Result<ControlSnapshot, ControlError> = switch settled {
            case .success(let snapshot):
                if let ending { .failure(ending.failure) } else { .success(snapshot) }
            case .failure(.work(let op, let failed, let failure)):
                if let refusal, refusal.index <= op {
                    .failure(refusal.failure)
                } else {
                    .failure(ControlError.actionWork(failure, action: actionIDs.dropFirst(op).first ?? "action.batch", method: method)
                        .atBatchOp(op, applied: applied, failed: failed).ranInPart())
                }
            case .failure(.other(let error)):
                .failure(ending?.failure ?? error)
            }
            let result: ControlIdempotencyCache.Outcome
            switch outcome {
            case .failure(let failure):
                result = .failure(failure)
            case .success(let snapshot):
                let value = await Self.resultValue(of: results)
                var reply = reply
                reply["created"] = .array(scope.created.compactMap { PublicIDTargetResolver.publicID(of: $0, in: snapshot.topology) }.map(JSONValue.string))
                reply["sequence"] = JSONValue.number(Double(snapshot.topology.daemonSequence))
                if let value { reply["result"] = value }
                result = .success(.object(reply))
            }
            if let key { idempotency.finish(key, with: result) }
            return result
        }
        guard wait else {
            if let ending { throw ending.failure }
            var immediate = reply
            immediate["created"] = []
            immediate["sequence"] = JSONValue.number(Double(snapshots.current.topology.daemonSequence))
            return .object(immediate)
        }
        return try await settling.value.get()
    }
}

extension ControlRouter {
    /// One slice of a batch, on the main actor: `requests` in order while the automation class may
    /// still run this frame (``MainFrameBudget/mayRun(_:)``: its budget not spent and no person's
    /// input pending), and at least one. Without the app's budget (tests, tools) the slice stops at
    /// `limit` of main-thread time. Stops after a run that did not run its action.
    @MainActor
    static func batchSlice(_ requests: [ControlActionRequest], executor: any ControlActionExecutor,
                           budget: MainFrameBudget?, limit: Duration) -> [ControlActionRun] {
        let started = ContinuousClock.now
        var ran: [ControlActionRun] = []
        for request in requests {
            let run = executor.performActionTracked(request)
            ran.append(run)
            guard case .ran = run.outcome else { break }
            if let budget {
                if !budget.mayRun(.automation) { break }
            } else if ContinuousClock.now - started >= limit {
                break
            }
        }
        return ran
    }
}

extension ControlError {
    /// This error marked as one of a request whose work started (`data.not_run` false): an
    /// `action.batch` cut short after some ops applied. ``annotated(progress:)`` keeps the mark,
    /// also when a retry with the key replays the error.
    func ranInPart() -> ControlError {
        var error = self
        var members = data?.objectValue ?? [:]
        members["not_run"] = false
        error.data = .object(members)
        return error
    }

    /// This error as op `index` of an `action.batch` (`data.op`); with `applied`, how many ops
    /// ran their handlers (`data.applied`: ops from there on never ran); with `failed`, every op
    /// whose work failed (`data.failed`).
    func atBatchOp(_ index: Int, applied: Int? = nil, failed: [Int]? = nil) -> ControlError {
        var error = self
        var members = data?.objectValue ?? [:]
        members["op"] = JSONValue(index)
        if let applied { members["applied"] = JSONValue(applied) }
        if let failed { members["failed"] = .array(failed.map { JSONValue($0) }) }
        error.data = .object(members)
        return error
    }
}
