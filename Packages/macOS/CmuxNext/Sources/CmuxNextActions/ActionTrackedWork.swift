/// Returns one registry-owned effect for helpers that report work and result tasks.
/// Existing helper deadlines and result fields remain intact.
@MainActor
public enum ActionTrackedWork {
    typealias Answer = Result<[String: ActionResultValue], ActionWorkFailure>

    public static func effect(
        registry: ActionRegistry,
        cancellationFailure: ActionWorkFailure,
        waiting: ActionWait = .network,
        authorize: @escaping @MainActor () async -> ActionWorkFailure? = { nil },
        cancelAuthorization: @escaping @MainActor () -> Void = {},
        start: @escaping @MainActor () -> ActionWorkFailure?
    ) -> ActionEffect {
        let scope = ActionRunScope.current
        let capturedByCaller = registry.isCapturingWork
        let answers = AsyncStream<Answer>.makeStream(bufferingPolicy: .bufferingOldest(1))
        if capturedByCaller {
            // task-owner: result-only relay; the registry effect below always finishes its stream.
            registry.track(result: Task {
                for await answer in answers.stream { return answer }
                return .failure(cancellationFailure)
            })
        }
        // action-wait-allow: the caller names its service wait; this adapter preserves helper work and result tracking.
        return .waiting(waiting) {
            let answer = await withTaskCancellationHandler {
                if let failure = await authorize() { return Answer.failure(failure) }
                guard !Task.isCancelled else { return Answer.failure(cancellationFailure) }
                return await run(registry: registry, scope: scope, cancellationFailure: cancellationFailure, start: start)
            } onCancel: {
                // task-owner: one-shot cancellation invalidates the reserved sign-in generation.
                Task { @MainActor in cancelAuthorization() }
            }
            answers.continuation.yield(answer)
            answers.continuation.finish()
            if case .failure(let failure) = answer { return failure }
            return nil
        }
    }

    private static func run(registry: ActionRegistry, scope: ActionRunScope?, cancellationFailure: ActionWorkFailure,
                            start: @MainActor () -> ActionWorkFailure?) async -> Answer {
        var captured: (work: [ActionWork], results: [ActionResultWork]) = ([], [])
        var startFailure: ActionWorkFailure?
        let refusal = ActionRunScope.carrying(scope) {
            registry.capturingRefusal {
                captured = registry.capturingRun { startFailure = start() }
            }
        }
        let work = captured.work, results = captured.results
        return await withTaskCancellationHandler {
            var failure = startFailure ?? refusal.map { ActionWorkFailure(refusal: .unavailable, reason: $0) }
            for task in work {
                if let next = await task.value, failure == nil { failure = next }
            }
            guard !Task.isCancelled else { return .failure(cancellationFailure) }
            if let failure { return .failure(failure) }
            var fields: [String: ActionResultValue] = [:]
            for task in results {
                switch await task.value {
                case .success(let next): fields.merge(next) { _, new in new }
                case .failure(let failure): return .failure(failure)
                }
            }
            return .success(fields)
        } onCancel: {
            for task in work { task.cancel() }
            for task in results { task.cancel() }
        }
    }
}
