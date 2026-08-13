import Foundation

enum SimulatorWorkerRequestTimeoutRecovery: Sendable {
    case restartWorker
    case preserveWorker
}

extension SimulatorWorkerClient {
    func requestWorkerValue<Value: Sendable>(
        sending message: SimulatorWorkerInbound,
        timeout: Duration = .seconds(60),
        timeoutRecovery: SimulatorWorkerRequestTimeoutRecovery = .restartWorker,
        matching: @escaping @Sendable (SimulatorWorkerOutbound) -> Value?
    ) async throws -> Value {
        let requestIdentifier = message.requestIdentifier
        let stream = if let requestIdentifier {
            try await registerRequestSubscriber(requestIdentifier)
        } else {
            await subscribe()
        }
        // The response deadline starts only after the command reaches the
        // worker. A request waiting behind replay remains cancellable without
        // performing a stale side effect later.
        do {
            try await sendRequired(message)
        } catch {
            if let requestIdentifier { await removeRequestSubscriber(requestIdentifier) }
            throw error
        }
        let requestGeneration = generation
        let sleeper = self.sleeper
        do {
            let value = try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask {
                    for await event in stream {
                        guard case let .message(outbound) = event else {
                            throw SimulatorControlError(
                                code: "worker_stopped",
                                arguments: [],
                                message: String(
                                    localized: "simulator.failure.workerStoppedBeforeResponse",
                                    defaultValue: "The Simulator worker stopped before replying."
                                )
                            )
                        }
                        if case let .requestFailure(responseID, failure) = outbound,
                           responseID == requestIdentifier {
                            throw failure
                        }
                        if let value = matching(outbound) { return value }
                    }
                    throw SimulatorControlError(
                        code: "worker_stopped",
                        arguments: [],
                        message: String(
                            localized: "simulator.failure.workerEventStreamClosed",
                            defaultValue: "The Simulator worker closed its event stream before replying."
                        )
                    )
                }
                group.addTask {
                    try await sleeper.sleep(for: timeout)
                    throw SimulatorControlError(
                        code: "worker_response_timed_out",
                        arguments: [],
                        message: String(
                            localized: "simulator.failure.workerResponseTimedOut",
                            defaultValue: "The Simulator worker did not reply before the bounded deadline."
                        )
                    )
                }
                guard let value = try await group.next() else {
                    throw SimulatorControlError(
                        code: "worker_stopped",
                        arguments: [],
                        message: String(
                            localized: "simulator.failure.workerResponseMissing",
                            defaultValue: "The Simulator worker did not produce a response."
                        )
                    )
                }
                group.cancelAll()
                return value
            }
            if let requestIdentifier { await removeRequestSubscriber(requestIdentifier) }
            return value
        } catch let error as SimulatorControlError
            where error.code == "worker_response_timed_out" {
            if let requestIdentifier { await removeRequestSubscriber(requestIdentifier) }
            if timeoutRecovery == .restartWorker {
                await correlatedOperationDeadlineExpired(
                    generation: requestGeneration,
                    failure: error
                )
            }
            throw error
        } catch {
            if let requestIdentifier { await removeRequestSubscriber(requestIdentifier) }
            throw error
        }
    }
}
