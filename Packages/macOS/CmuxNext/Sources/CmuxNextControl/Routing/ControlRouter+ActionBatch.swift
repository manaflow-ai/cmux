import CmuxNextActions
public import CmuxNextSettings
import Foundation

/// `action.batch`: many app actions in one request (CLAUDE.md "Go past Chrome where cmux is
/// scripted": a burst of scripted changes is one request and one main-thread task, not one per op).
///
/// Params: `ops`, an array of `action.run` param objects (`action` or `cli_name` with `cli`,
/// `target`, `args`, `focus`, `background`, `origin`); and for the whole batch `wait` (default
/// true), `idempotency_key`, `atomic` (default true), `after` (read barrier) and `caller`.
///
/// - Every op is resolved and validated off the main actor before any runs. One invalid op
///   refuses the whole batch: `not_run`, with `data.op` its index.
/// - The ops run in order in one main-actor work item, an automation task of the main-thread
///   scheduler. What the app owns (selection, focus, settings, app-local state) changes in that
///   one task, so it shows together. What the session daemon owns (a daemon tab renamed, a
///   column made, a close) the task only sends: it shows as the daemon's echoes arrive and the
///   store applies them, which can take more than one frame and more than one store publish.
/// - Not all-or-nothing: a handler that refuses at run time stops the batch there. The ops before
///   it stay applied (`data.applied` counts them), the rest never run. The same holds for a later transaction
///   of `atomic: false` that never ran (its deadline passed in the queue, the queue was full):
///   that answer is never `not_run`. The daemon work an op started (a rename, a close) fails
///   after the ops after it ran, so it does not stop them: the answer names the first op whose
///   work failed (`data.op`, with its own action), every such op (`data.failed`) and how many ops
///   ran (`data.applied`); an earlier failure answers before a later refusal.
/// - Bounded: at most ``ControlRouter/Configuration/batchOpLimit`` ops. A larger batch is
///   `batch_too_large` (`not_run`, naming the limit) unless `atomic` is false, which runs it as
///   consecutive work items of at most the limit each, in order.
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
        let ops = try Self.batchOps(call.params)
        let atomic = try Self.batchAtomic(call.params)
        let limit = configuration.batchOpLimit
        if atomic, ops.count > limit {
            throw ControlError(code: "batch_too_large",
                               message: ControlStrings.format("control.error.batchTooLarge",
                                                              "action.batch takes at most %1$lld ops in one transaction (got %2$lld); send several batches, or atomic: false to apply it as consecutive transactions",
                                                              limit, ops.count),
                               data: ["ops": JSONValue(ops.count), "limit": JSONValue(limit)])
        }
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
            try await self.executeBatch(given, key: key, transactionSize: atomic ? given.count : limit, call: call)
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
    static let batchLevelMembers = ["wait", "idempotency_key", "after", "caller", "atomic"]

    static func batchAtomic(_ params: [String: JSONValue]) throws -> Bool {
        guard let value = params["atomic"], !value.isNull else { return true }
        guard let flag = value.boolValue else {
            throw ControlError.invalidParams(ControlStrings.text("control.error.batchAtomicShape", "atomic must be true or false"))
        }
        return flag
    }

    private func executeBatch(_ given: [(action: ControlActionInfo, request: ControlActionRequest)], key: String?,
                              transactionSize: Int, call: ControlCall) async throws -> JSONValue {
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
        let size = max(transactionSize, 1)
        // Why a later transaction never ran, when earlier ones applied.
        var cutShort: ControlError?
        do {
            for start in stride(from: 0, to: requests.count, by: size) {
                let transaction = Array(requests.dropFirst(start).prefix(size))
                let ran = try await workQueue.run(connection: call.connection, method: call.method, deadline: call.deadline,
                                                  countingFrom: call.engineStartMark) { () throws -> [ControlActionRun] in
                    // The request may have answered `not_run` already: then never run.
                    guard progress.begin(), scope.noting("handler") else { throw expired }
                    // The queue runs this from a run-loop block, where no task is current (cx-bpcj).
                    return ControlCommandScope.$current.withValueInTask(scope) {
                        var ran: [ControlActionRun] = []
                        ran.reserveCapacity(transaction.count)
                        for request in transaction {
                            let run = executor.performActionTracked(request)
                            ran.append(run)
                            guard case .ran = run.outcome else { break }
                        }
                        return ran
                    }
                }
                runs += ran
                guard ran.count == transaction.count, ran.last.map({ if case .ran = $0.outcome { true } else { false } }) ?? false else { break }
            }
        } catch let error as ControlError where !runs.isEmpty {
            // A later transaction never ran (its deadline passed in the queue, the queue was full)
            // after earlier ones applied: the batch ends there, as at a refusal. Its answer says
            // how many ops applied and that the request did run (never `not_run`, which a client
            // reads as safe to send again: the applied ops would run twice).
            cutShort = error.atBatchOp(runs.count, applied: runs.count).ranInPart()
        }
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
