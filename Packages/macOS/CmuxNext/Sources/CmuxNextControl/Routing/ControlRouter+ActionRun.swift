import CmuxNextActions
public import CmuxNextSettings
import Foundation

/// `action.run` (plans/cmux-next/state-ownership.md 4).
///
/// Params: `action` (id or CLI name; with `cli: true` only a CLI name of an
/// action marked for the CLI), `target`, `args`, `wait` (default true),
/// `idempotency_key`, `confirm` via args, `after` (read barrier).
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
        let catalog = call.snapshot.catalog
        let action = try Self.resolveAction(call.params, in: catalog)
        let given = try Self.validatedRequest(for: action, params: call.params, knownKinds: catalog.targetKinds)
        let key = try Self.idempotencyKey(call.params)
        guard let key else { return try await execute(action, given, key: nil, call: call) }
        switch idempotency.claim(key, fingerprint: given) {
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
                               data: ["idempotency_key": .string(key)])
        }
        do {
            return try await execute(action, given, key: key, call: call)
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

    private func execute(_ action: ControlActionInfo, _ given: ControlActionRequest, key: String?, call: ControlCall) async throws -> JSONValue {
        let request = try await resolvedTargets(given, snapshot: call.snapshot, deadline: call.deadline)
        guard call.snapshot.catalog.isAvailable(action, target: request.target) || action.unavailableReason != nil else {
            throw ControlError(code: "unavailable", message: ControlStrings.format("control.error.actionNotAvailableInContext", "%@ is not available in the current context", action.id), data: [
                "action": .string(action.id), "requires": .array(action.requires.map(JSONValue.string)),
            ])
        }
        if action.isDestructive, request.arguments["confirm"] != .bool(true) {
            throw Self.confirmationRequired(action.id)
        }
        let executor = self.executor
        let progress = call.progress
        let wait = call.params["wait"]?.boolValue ?? true
        let scope = ControlCommandScope(idempotencyKey: key)
        let expired = ControlError.timeout(call.method, after: max(call.deadline - .now, .zero))
        let run = try await workQueue.run(connection: call.connection, method: call.method, deadline: call.deadline) {
            // The request may have answered `not_run` already: then never run.
            guard progress.begin() else { throw expired }
            return ControlCommandScope.$current.withValue(scope) { executor.performActionTracked(request) }
        }
        do {
            try Self.check(run.outcome, action: action.id)
        } catch let error as ControlError {
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
            let settled = await settle(run, scope: scope, action: action.id, method: call.method, deadline: settleDeadline)
            let result = settled.map { snapshot -> JSONValue in
                var reply = reply
                if let target = request.target { reply["resolved"] = resolvedJSON(target, in: snapshot.topology) }
                reply["created"] = .array(scope.created.compactMap { PublicIDTargetResolver.publicID(of: $0, in: snapshot.topology) }.map(JSONValue.string))
                reply["sequence"] = JSONValue.number(Double(snapshot.topology.daemonSequence))
                return .object(reply)
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
            return .object(immediate)
        }
        return try await settling.value.get()
    }

    /// `target` resolved to the object's public id, with the model key the handler got.
    func resolvedJSON(_ target: ControlTargetRef, in topology: ControlTopology) -> JSONValue {
        ["kind": .string(target.kind), "id": .string(PublicIDTargetResolver.publicID(of: target, in: topology)), "key": .string(target.id)]
    }

    /// Waits for the run's work, then for a snapshot that reflects it.
    /// Returns that snapshot or the first failure.
    private func settle(_ run: ControlActionRun, scope: ControlCommandScope, action: String, method: String,
                        deadline: ContinuousClock.Instant) async -> Result<ControlSnapshot, ControlError> {
        defer { scope.close() }
        let failure: ActionWorkFailure?
        do {
            failure = try await ControlDeadline.shared.run(method: method, deadline: deadline) {
                let tracked = await Self.firstFailure(of: run.work)
                await Self.awaitIdle(scope)
                return tracked
            }
        } catch {
            return .failure(Self.stillRunning(method, action: action))
        }
        if let failure { return .failure(Self.workError(failure, action: action, method: method)) }
        if let failure = scope.failures.first { return .failure(Self.scopeError(failure, action: action, method: method)) }
        // No daemon command: the work queue's frame already published the
        // app-local change (selection, focus, settings).
        let barriers = scope.barriers
        guard !barriers.isEmpty else { return .success(snapshots.current) }
        guard let snapshot = await snapshots.snapshot(reflecting: Self.sequenceBarrier(barriers, in: snapshots.current.topology),
                                                      deadline: deadline) else {
            return .failure(Self.stillRunning(method, action: action))
        }
        return .success(snapshot)
    }

    /// The scope's per-machine barriers as snapshot sequences: the local
    /// daemon's is the home sequence, a remote machine's its session's. A
    /// machine the topology no longer lists cannot be waited for.
    static func sequenceBarrier(_ barriers: [String: UInt64], in topology: ControlTopology) -> ControlSequenceBarrier {
        var barrier = ControlSequenceBarrier(home: barriers[ControlCommandScope.localMachine] ?? 0)
        for (machine, sequence) in barriers where machine != ControlCommandScope.localMachine {
            guard let session = topology.sessions.first(where: { $0.machineID == machine && !$0.isHome }) else { continue }
            barrier.sessions[session.id] = sequence
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
        workError(ActionWorkFailure(failure.message, mayHaveApplied: failure.mayHaveApplied, terminalMayAppear: failure.terminalMayAppear),
                  action: action, method: method)
    }

    /// Maps a non-`ran` outcome to its error.
    static func check(_ outcome: ControlActionOutcome, action: String) throws {
        switch outcome {
        case .ran:
            return
        case .unknownAction:
            throw ControlError(code: "not_found", message: ControlStrings.format("control.error.unknownAction", "Unknown action '%@'", action))
        case .notBound:
            throw ControlError(code: "not_bound", message: ControlStrings.format("control.error.actionNotBound", "%@ has no handler in this build", action), data: ["action": .string(action)])
        case .unavailable:
            throw ControlError(code: "unavailable", message: ControlStrings.format("control.error.actionNotAvailableInContext", "%@ is not available in the current context", action), data: ["action": .string(action)])
        case .disabled:
            throw ControlError(code: "disabled", message: ControlStrings.format("control.error.actionDisabled", "%@ is disabled right now", action), data: ["action": .string(action)])
        case .refused(let reason):
            throw ControlError(code: "unavailable", message: ControlStrings.format("control.error.actionUnavailableReason", "%1$@ unavailable: %2$@", action, reason), data: ["action": .string(action), "reason": .string(reason)])
        case .notFound(let reason):
            throw ControlError(code: "not_found", message: reason, data: ["action": .string(action), "reason": .string(reason)])
        case .confirmationRequired:
            throw confirmationRequired(action)
        }
    }

    /// Runs the target resolver over the target and every target argument,
    /// against `snapshot` (the read barrier's, when the request passed `after`).
    func resolvedTargets(_ request: ControlActionRequest, snapshot: ControlSnapshot, deadline: ContinuousClock.Instant) async throws -> ControlActionRequest {
        let topology = snapshot.topology
        let resolver: TargetResolver = targetResolver ?? { ref, _ in try PublicIDTargetResolver.resolve(ref, in: topology) }
        var resolved = request
        if let target = request.target { resolved.target = try await resolver(target, deadline) }
        for (name, value) in request.arguments {
            if case .target(let ref) = value { resolved.arguments[name] = .target(try await resolver(ref, deadline)) }
        }
        return resolved
    }
}
