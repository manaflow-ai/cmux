import CmuxNextActions
public import CmuxNextSettings
import Foundation
import os

/// `action.run` (plans/cmux-next/state-ownership.md 4).
///
/// Params: `action` (id or CLI name; with `cli: true` only a CLI name of an
/// action marked for the CLI), `target`, `args`, `wait` (default true),
/// `idempotency_key`, `confirm` via args, `after` (read barrier), `caller`
/// (the agent session or terminal that sent it: an agent's browser or diff
/// with no target opens beside its chat, ControlCaller).
///
/// With `wait`, the reply comes after every daemon command the action sent
/// has replied, the store applied their echoes, and the control snapshot
/// that reflects them was published. The handler runs with a
/// ``ControlCommandScope`` bound, so commands from any task it started count
/// and derive their mutation ids from the idempotency key.
extension ControlRouter {
    /// How long a started run keeps settling after its request answered
    /// `in_progress`, so a retry with the same key gets the final reply.
    static let settleLimit: Duration = .seconds(30)

    func runAction(_ call: ControlCall) async throws -> JSONValue {
        do {
            return try await startAction(call)
        } catch let error as ControlError where !call.progress.hasStarted && error.code != "timeout" {
            // Refused before the handler ran: nothing applied (a timeout gets its mark from the progress).
            throw error.notRun()
        }
    }

    /// Claims the original request before deriving a topology-dependent action. Only a new run
    /// calls `preparing`; execution keeps the original key through settlement and caches the mapped
    /// reply, so a retry neither changes target nor needs the original objects to still exist.
    func runAction(_ call: ControlCall, fingerprint: ControlIdempotencyCache.Fingerprint,
                   preparing: () throws -> (ControlCall, @Sendable (JSONValue) -> JSONValue)) async throws -> JSONValue {
        do {
            let key = try Self.idempotencyKey(call.params)
            return try await keyed(key, fingerprint: fingerprint, call: call) {
                let (derived, mapReply) = try preparing()
                let action = try Self.resolveAction(derived.params, in: derived.snapshot.catalog)
                let given = try Self.validated(action, params: derived.params, call: derived, caller: try ControlCaller(derived.params))
                return try await self.execute(action, given, key: key, call: derived, mapReply: mapReply)
            }
        } catch let error as ControlError where !call.progress.hasStarted && error.code != "timeout" {
            throw error.notRun()
        }
    }

    private func startAction(_ call: ControlCall) async throws -> JSONValue {
        let action = try Self.resolveAction(call.params, in: call.snapshot.catalog)
        let given = try Self.validated(action, params: call.params, call: call, caller: try ControlCaller(call.params))
        let key = try Self.idempotencyKey(call.params)
        return try await keyed(key, fingerprint: .run(given), call: call) {
            try await self.execute(action, given, key: key, call: call)
        }
    }

    /// Runs `body` under idempotency key `key` (`action.run`, `action.batch`): a finished run
    /// with the key replays its reply, an active one is joined, another request with the key is
    /// a conflict, and a run that never started forgets the key so a retry runs.
    func keyed(_ key: String?, fingerprint: ControlIdempotencyCache.Fingerprint, call: ControlCall,
               _ body: () async throws -> JSONValue) async throws -> JSONValue {
        guard let key else { return try await body() }
        switch idempotency.claim(key, fingerprint: fingerprint) {
        case .run:
            break
        case .finished(let outcome):
            _ = call.progress.begin()
            return try Self.replayed(outcome)
        case .join(let joiner):
            // The keyed run is active: a timeout while waiting says `in_progress`.
            _ = call.progress.begin()
            guard let outcome = await joiner.outcome() else {
                // It never started after all: say `not_run` explicitly.
                throw ControlError(code: "timeout", message: ControlStrings.format("control.error.idempotentRunNotStarted",
                                                                                   "The earlier run with idempotency key %@ never started; retry", key),
                                   data: ["idempotency_key": .string(key), "not_run": true])
            }
            return try Self.replayed(outcome)
        case .conflict:
            _ = call.progress.begin()
            throw ControlError(code: "idempotency_conflict",
                               message: ControlStrings.format("control.error.idempotencyConflict", "Idempotency key %@ was used for a different request", key),
                               data: ["idempotency_key": .string(key)]).notRun()
        }
        do {
            return try await body()
        } catch let error as ControlError where !call.progress.hasStarted {
            // Never ran (invalid, not found, busy, expired in the queue): a retry runs.
            idempotency.forget(key)
            throw error
        }
    }

    static func idempotencyKey(_ params: [String: JSONValue]) throws -> String? {
        switch params["idempotency_key"] {
        case nil, .null: return nil
        case .string(let key) where !key.isEmpty && key.count <= 200: return key
        default:
            throw ControlError.invalidParams(ControlStrings.text("control.error.idempotencyKeyShape",
                                                                 "idempotency_key must be a non-empty string of at most 200 characters"))
        }
    }

    static func replayed(_ outcome: ControlIdempotencyCache.Outcome) throws -> JSONValue {
        guard case .object(var members) = try outcome.get() else { return try outcome.get() }
        members["replayed"] = true
        return .object(members)
    }

    /// `params` (one `action.run` request, or one op of `action.batch`) checked against `action`'s
    /// schema, with the request's calling app and `caller`. The caller is part of the idempotency
    /// fingerprint; where it places is resolved per run (``prepared(_:_:call:)``), so a retry with
    /// the key replays, never conflicts.
    static func validated(_ action: ControlActionInfo, params: [String: JSONValue], call: ControlCall,
                          caller: ControlCaller?) throws -> ControlActionRequest {
        var given = try validatedRequest(for: action, params: params, knownKinds: call.snapshot.catalog.targetKinds,
                                         connection: call.connection)
        given.callerApp = call.request.callerApp
        given.callerAgentSession = caller?.agentSession
        given.callerTerminal = caller?.terminalID
        given.callerHomeChat = caller?.homeChat ?? false
        return given
    }

    /// `given` aimed beside its caller, with its targets resolved, checked: available in the
    /// current context, and confirmed when destructive. Runs off the main actor.
    func prepared(_ action: ControlActionInfo, _ given: ControlActionRequest, call: ControlCall) async throws -> ControlActionRequest {
        var placed = given
        try Self.placeBesideCaller(&placed, action: action, topology: call.snapshot.topology)
        try Self.aimBrowserActionAtCaller(&placed, action: action, topology: call.snapshot.topology)
        let request = try await resolvedTargets(placed, snapshot: call.snapshot, deadline: call.deadline)
        guard call.snapshot.catalog.isAvailable(action, target: request.target) || action.unavailableReason != nil else {
            throw ControlError(code: "unavailable", message: ControlStrings.format("control.error.actionNotAvailableInContext", "%@ is not available in the current context", action.id), data: [
                "action": .string(action.id), "requires": .array(action.requires.map(JSONValue.string)),
            ])
        }
        if action.isDestructive, request.arguments["confirm"] != .bool(true) {
            throw ControlError.confirmationRequired(action.id)
        }
        return request
    }

    private func execute(_ action: ControlActionInfo, _ given: ControlActionRequest, key: String?, call: ControlCall,
                         mapReply: @escaping @Sendable (JSONValue) -> JSONValue = { $0 }) async throws -> JSONValue {
        let request = try await prepared(action, given, call: call)
        let executor = self.executor
        let progress = call.progress
        let wait = call.params["wait"]?.boolValue ?? true
        let scope = progress.track(ControlCommandScope(idempotencyKey: key))
        let expired = ControlError.timeout(call.method, after: max(call.deadline - .now, .zero))
        // A later step of a composite call (`file.open`'s next path) follows steps that may have applied.
        let firstStep = !progress.hasStarted
        let run = try await workQueue.run(connection: call.connection, method: call.method, owner: call.owner, deadline: call.deadline,
                                          countingFrom: call.engineStartMark) {
            // The request may have answered `not_run` already: then never run.
            guard progress.begin(), scope.noting("handler") else { throw expired }
            if action.id == "tab.focus" { tabSwitchMark("run") }
            // The queue runs this from a run-loop block, where no task is current (cx-bpcj).
            return ControlCommandScope.$current.withValueInTask(scope) { executor.performActionTracked(request) }
        }
        do {
            try Self.check(run.outcome, action: action.id)
        } catch var error as ControlError {
            // A refusal that started no work applied nothing; one that did may have applied part.
            if run.work.isEmpty, firstStep { error = error.notRun() }
            // The run started, so `runAction` keeps the key: record the refusal.
            if let key { idempotency.finish(key, with: .failure(error)) }
            throw error
        }
        let reply: [String: JSONValue] = [
            "action": .string(action.id),
            "ran": true,
            "waited": .bool(wait),
            "args": .object(request.arguments.mapValues(\.json)),
            "target": call.params["target"] ?? .null,
            "idempotency_key": .optional(key),
        ]
        let settleDeadline = max(call.deadline, .now + Self.settleLimit)
        // Unstructured on purpose: a request that times out (or does not
        // wait) answers while the run keeps settling, and the key stays
        // pending until settlement records the final reply for a retry.
        let settling = Task { [self] () -> ControlIdempotencyCache.Outcome in
            let settled = await settle(run, scope: scope, action: action.id, method: call.method, deadline: settleDeadline, replyBy: { call.movedDeadline })
            // Settled: every result task already finished with the work that awaited it.
            let value = await Self.resultValue(of: run.results)
            let result = settled.map { snapshot -> JSONValue in
                var reply = reply
                if let target = request.target { reply["resolved"] = resolvedJSON(target, in: snapshot.topology) }
                reply["created"] = .array(scope.created.compactMap { PublicIDTargetResolver.publicID(of: $0, in: snapshot.topology) }.map(JSONValue.string))
                reply["sequence"] = JSONValue.number(Double(snapshot.topology.daemonSequence))
                if let value { reply["result"] = value }
                return mapReply(.object(reply))
            }
            if let key { idempotency.finish(key, with: result) }
            return result
        }
        guard wait else {
            // The scope keeps deriving mutation ids until the handler's work settles.
            var immediate = reply
            if let target = request.target { immediate["resolved"] = resolvedJSON(target, in: call.snapshot.topology) }
            immediate["created"] = []
            immediate["sequence"] = JSONValue.number(Double(snapshots.current.topology.daemonSequence))
            return mapReply(.object(immediate))
        }
        return try await settling.value.get()
    }

    /// The fields the run's value-producing work returned (`ActionRegistry.track(result:)`),
    /// merged in order, as the reply's `result`; nil when it produced none.
    static func resultValue(of results: [ActionResultWork]) async -> JSONValue? {
        var fields: [String: JSONValue] = [:]
        for task in results {
            guard case .success(let value) = await task.value else { continue }
            for (key, field) in value { fields[key] = json(field) }
        }
        return results.isEmpty ? nil : .object(fields)
    }

    static func json(_ value: ActionResultValue) -> JSONValue {
        switch value {
        case .string(let text): .string(text)
        case .int(let number): JSONValue(number)
        case .double(let number): .number(number)
        case .bool(let flag): .bool(flag)
        case .null: .null
        case .array(let items): .array(items.map(json))
        case .object(let members): .object(members.mapValues(json))
        }
    }

    /// `target` resolved to the object's public id, with the model key the handler got.
    func resolvedJSON(_ target: ControlTargetRef, in topology: ControlTopology) -> JSONValue {
        ["kind": .string(target.kind), "id": .string(PublicIDTargetResolver.publicID(of: target, in: topology)), "key": .string(target.id)]
    }

    /// Waits for the run's work, then for a snapshot that reflects it.
    /// Returns that snapshot or the first failure.
    func settle(_ run: ControlActionRun, scope: ControlCommandScope, action: String, method: String,
                        deadline: ContinuousClock.Instant, replyBy: @Sendable () -> ContinuousClock.Instant) async -> Result<ControlSnapshot, ControlError> {
        defer { scope.close() }
        let failure: ActionWorkFailure?
        do {
            failure = try await ControlDeadline.shared.run(method: method, deadline: deadline) {
                let tracked = await scope.stage("work") { await Self.firstFailure(of: run.work) }
                await scope.stage("daemon") { await Self.awaitIdle(scope) }
                return tracked
            }
        } catch {
            return .failure(Self.stillRunning(method, action: action))
        }
        if let failure { return .failure(ControlError.actionWork(failure, action: action, method: method)) }
        if let failure = scope.failures.first { return .failure(Self.scopeError(failure, action: action, method: method)) }
        // No daemon command: the work queue's frame already published the
        // app-local change (selection, focus, settings).
        let barriers = scope.snapshotBarriers()
        guard !barriers.isEmpty else { return .success(await snapshots.showing(scope.created, after: snapshots.current, replyBy: replyBy())) }
        guard let snapshot = await snapshots.snapshot(reflecting: Self.sequenceBarrier(barriers, in: snapshots.current.topology),
                                                      deadline: deadline) else {
            return .failure(Self.stillRunning(method, action: action))
        }
        return .success(await snapshots.showing(scope.created, after: snapshot, replyBy: replyBy()))
    }

    /// The scope's per-machine barriers as snapshot sequences: the local
    /// daemon's is the home sequence, a remote machine's its session's. A
    /// machine the topology no longer lists cannot be waited for.
    static func sequenceBarrier(_ barriers: [String: UInt64], in topology: ControlTopology) -> ControlSequenceBarrier {
        var barrier = ControlSequenceBarrier(home: barriers[ControlCommandScope.localMachine] ?? 0)
        for (machine, sequence) in barriers where machine != ControlCommandScope.localMachine {
            guard let session = topology.sessions.first(where: { $0.machineID == machine && !$0.isHome }) else { continue }
            barrier.sessions.updateValue(sequence, forKey: session.id)
        }
        return barrier
    }

    /// Returns once no command of `scope` is open, checked on the main
    /// actor: the tasks a handler started are main-actor tasks queued before
    /// this hop, so each has opened its first ticket by the time it runs,
    /// and a task opens its next ticket before yielding the main actor.
    static func awaitIdle(_ scope: ControlCommandScope) async {
        // wakeup-allow: each iteration waits for the scope's open commands to reply, never polls
        while !Task.isCancelled {
            if await MainActor.run(body: { scope.isIdle }) { return }
            await scope.waitUntilIdle()
        }
    }

    static func stillRunning(_ method: String, action: String) -> ControlError {
        var error = ControlError.timeout(method, after: .zero)
        error.data = ["method": .string(method), "action": .string(action)]
        return error
    }

    static func scopeError(_ failure: ControlCommandScope.Failure, action: String, method: String) -> ControlError {
        ControlError.actionWork(ActionWorkFailure(failure.message, mayHaveApplied: failure.mayHaveApplied, terminalMayAppear: failure.terminalMayAppear),
                  action: action, method: method)
    }

    /// Maps a non-`ran` outcome to its error.
    static func check(_ outcome: ControlActionOutcome, action: String) throws {
        if let error = ControlError.actionOutcome(outcome, action: action) { throw error }
    }

    /// Runs the target resolver over the target and every target argument,
    /// against `snapshot` (the read barrier's, when the request passed `after`).
    func resolvedTargets(_ request: ControlActionRequest, snapshot: ControlSnapshot, deadline: ContinuousClock.Instant) async throws -> ControlActionRequest {
        let topology = snapshot.topology
        let resolver: TargetResolver = targetResolver ?? { ref, _ in try PublicIDTargetResolver.resolve(ref, in: topology) }
        var resolved = request
        if let target = request.target { resolved.target = try await resolver(target, deadline) }
        for (name, value) in request.arguments {
            if case .target(let ref) = value { resolved.arguments.updateValue(.target(try await resolver(ref, deadline)), forKey: name) }
        }
        return resolved
    }
}

/// Tab switch timeline marks (cx-asb1): wall-clock ms, so a bench can line
/// them up with the page's own clock. Debug level: nothing is written unless
/// a `log stream --level debug` reads category "tab-switch".
private let tabSwitchLog = Logger(subsystem: "com.cmuxterm.app.next", category: "tab-switch")
private func tabSwitchMark(_ name: String) {
    tabSwitchLog.debug("tab-switch \(name, privacy: .public) \(Date().timeIntervalSince1970 * 1_000, format: .fixed(precision: 3), privacy: .public)")
}
