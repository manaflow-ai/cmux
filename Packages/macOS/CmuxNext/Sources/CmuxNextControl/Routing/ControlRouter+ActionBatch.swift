import CmuxNextActions
public import CmuxNextSettings
import Foundation

/// `action.batch`: many app actions in one request (CLAUDE.md "Go past Chrome where cmux is
/// scripted": a burst of scripted changes applies as one transaction).
///
/// Params: `ops`, an array of `action.run` param objects (`action` or `cli_name` with `cli`,
/// `target`, `args`, `focus`, `background`, `origin`); and for the whole batch `wait` (default
/// true), `idempotency_key`, `atomic` (default true), `after` (read barrier) and `caller`.
///
/// - Every op is resolved and validated off the main actor before any runs. One invalid op
///   refuses the whole batch: `not_run`, with `data.op` its index.
/// - The ops run in order in one main-actor work item, an automation task of the main-thread
///   scheduler: the person never sees a frame with half the batch, and the model publishes once.
/// - An op the App would refuse as not available (a pane or tab target that shows no chat)
///   refuses the batch before any op runs, `atomic` or not: `not_run`, with `data.op` its index.
/// - A handler that refuses at run time stops the batch there: the ops before it ran
///   (`data.applied`), the rest did not.
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
        let all = requests
        do {
            for start in stride(from: 0, to: requests.count, by: size) {
                let transaction = Array(requests.dropFirst(start).prefix(size))
                let ran = try await workQueue.run(connection: call.connection, method: call.method, deadline: call.deadline,
                                                  countingFrom: call.engineStartMark) { () throws -> [ControlActionRun] in
                    // Before the first op: an op the App would refuse here (a pane or tab target's
                    // live chat or canvas facts) refuses the whole batch, also `atomic: false`, before
                    // any op applies. A later op that becomes unavailable is refused when it runs.
                    if start == 0, let index = executor.firstUnavailable(all) {
                        let action = all.dropFirst(index).first?.actionID ?? call.method
                        throw (ControlError.actionOutcome(.unavailable, action: action) ?? expired).atBatchOp(index)
                    }
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
        } catch var error as ControlError where !runs.isEmpty {
            // A later transaction never ran (its deadline passed in the queue, the queue was full)
            // after earlier ones applied: the batch's answer says how many did, under its key too,
            // so a retry gets it instead of joining a run that will not come.
            error = error.atBatchOp(runs.count, applied: runs.count)
            if let key { idempotency.finish(key, with: .failure(error)) }
            throw error
        }
        // The last run is the refused one when the batch stopped early.
        let refused = zip(given, runs).enumerated().reversed().first.flatMap { index, pair -> (index: Int, action: String, error: ControlError)? in
            guard let error = ControlError.actionOutcome(pair.1.outcome, action: pair.0.action.id) else { return nil }
            return (index, pair.0.action.id, error)
        }
        let applied = refused?.index ?? runs.count
        let work = ControlActionRun(outcome: .ran, work: runs.flatMap(\.work), results: runs.flatMap(\.results))
        if let refused {
            // A refusal that started no work applied nothing.
            var failure = refused.error.atBatchOp(refused.index, applied: applied)
            if applied == 0, work.work.isEmpty { failure = failure.notRun() }
            if wait, applied > 0 {
                // The ops before it ran: the reply comes once they settled, as a run's would.
                _ = await settle(work, scope: scope, action: refused.action, method: call.method, deadline: call.deadline,
                                 replyBy: { call.movedDeadline })
            }
            if let key { idempotency.finish(key, with: .failure(failure)) }
            throw failure
        }
        let reply: [String: JSONValue] = [
            "ran": JSONValue(applied),
            "waited": .bool(wait),
            "ops": .array(zip(given, requests).map { op, request in
                ["action": .string(op.action.id), "args": .object(request.arguments.mapValues(\.json))]
            }),
            "idempotency_key": .optional(key),
        ]
        let settleDeadline = max(call.deadline, .now + Self.settleLimit)
        // Unstructured on purpose (as `action.run`): a request that times out or does not wait
        // answers while the batch keeps settling; the key stays pending until it settled.
        let settling = Task { [self] () -> ControlIdempotencyCache.Outcome in
            let settled = await settle(work, scope: scope, action: "action.batch", method: call.method, deadline: settleDeadline,
                                       replyBy: { call.movedDeadline })
            let value = await Self.resultValue(of: work.results)
            let result = settled.map { snapshot -> JSONValue in
                var reply = reply
                reply["created"] = .array(scope.created.compactMap { PublicIDTargetResolver.publicID(of: $0, in: snapshot.topology) }.map(JSONValue.string))
                reply["sequence"] = JSONValue.number(Double(snapshot.topology.daemonSequence))
                if let value { reply["result"] = value }
                return .object(reply)
            }
            if let key { idempotency.finish(key, with: result) }
            return result
        }
        guard wait else {
            var immediate = reply
            immediate["created"] = []
            immediate["sequence"] = JSONValue.number(Double(snapshots.current.topology.daemonSequence))
            return .object(immediate)
        }
        return try await settling.value.get()
    }
}

extension ControlError {
    /// This error as op `index` of an `action.batch` (`data.op`), and with `applied`, how many
    /// ops before it ran (`data.applied`).
    func atBatchOp(_ index: Int, applied: Int? = nil) -> ControlError {
        var error = self
        var members = data?.objectValue ?? [:]
        members["op"] = JSONValue(index)
        if let applied { members["applied"] = JSONValue(applied) }
        error.data = .object(members)
        return error
    }
}
