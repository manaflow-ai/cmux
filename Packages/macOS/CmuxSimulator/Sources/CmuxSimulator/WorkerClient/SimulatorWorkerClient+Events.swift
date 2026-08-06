import Foundation

extension SimulatorWorkerClient {
    func removeSubscriber(_ identifier: Int) {
        subscribers.removeValue(forKey: identifier)
    }

    func requireOpen() throws {
        guard !isPermanentlyStopped else {
            throw SimulatorControlError(
                code: "worker_permanently_stopped",
                arguments: arguments,
                message: String(
                    localized: "simulator.failure.workerClientStopped",
                    defaultValue: "The Simulator worker client is permanently stopped."
                )
            )
        }
    }

    func registerRequestSubscriber(_ requestIdentifier: UUID) async throws -> SimulatorWorkerEventStream {
        guard requestSubscribers.count < Self.maximumPendingRequestCount else {
            throw SimulatorControlError(
                code: "worker_request_capacity_exceeded",
                arguments: [],
                message: String(
                    localized: "simulator.failure.workerRequestCapacityExceeded",
                    defaultValue: "The Simulator worker has too many pending requests."
                )
            )
        }
        guard requestSubscribers[requestIdentifier] == nil else {
            throw SimulatorControlError(
                code: "duplicate_worker_request",
                arguments: [],
                message: String(
                    localized: "simulator.failure.workerRequestIdentifierDuplicate",
                    defaultValue: "A Simulator worker request reused an active identifier."
                )
            )
        }
        let source = SimulatorWorkerEventStreamSource(
            maximumBufferedBytes: Self.maximumSubscriberBufferedBytes,
            // Camera configuration has a bounded two-message handshake:
            // target resolution followed by the final configuration result.
            maximumBufferedEvents: 2
        ) { [weak self] in
            Task { await self?.removeRequestSubscriber(requestIdentifier) }
        }
        requestSubscribers[requestIdentifier] = source.continuation
        return source.stream
    }

    func removeRequestSubscriber(_ requestIdentifier: UUID) async {
        await requestSubscribers.removeValue(forKey: requestIdentifier)?.finish()
    }

    func broadcast(_ event: SimulatorWorkerEvent, byteCount: Int? = nil) async {
        let chargedBytes = byteCount ?? estimatedByteCount(of: event)
        if case .workerStopped = event {
            let pendingRequests = requestSubscribers
            requestSubscribers.removeAll()
            for continuation in pendingRequests.values {
                await continuation.finish()
            }
        }
        if case let .message(message) = event,
           let requestIdentifier = message.requestIdentifier {
            if let continuation = requestSubscribers[requestIdentifier] {
                switch await continuation.yield(event, byteCount: chargedBytes) {
                case .enqueued:
                    if case .textInput = message {
                        break
                    }
                    return
                case .overflow, .terminated:
                    await removeRequestSubscriber(requestIdentifier)
                @unknown default:
                    break
                }
            }
            if case .textInput = message {
                // Pane callbacks and the control-socket receipt share this
                // completion, so text replies intentionally have two bounded
                // consumers. Other correlated replies stay request-private.
            } else {
                return
            }
        }
        var overflowed: [Int] = []
        var terminated: [Int] = []
        for (identifier, continuation) in subscribers {
            switch await continuation.yield(event, byteCount: chargedBytes) {
            case .enqueued:
                break
            case .overflow:
                overflowed.append(identifier)
            case .terminated:
                terminated.append(identifier)
            @unknown default:
                break
            }
        }
        for identifier in Set(overflowed + terminated) {
            await subscribers.removeValue(forKey: identifier)?.finish()
        }
        guard !overflowed.isEmpty, child != nil else { return }
        let failure = SimulatorFailure(
            code: "worker_subscriber_queue_overflow",
            message: String(
                localized: "simulator.failure.subscriberQueueOverflow",
                defaultValue: "A Simulator event subscriber exceeded its bounded queue."
            ),
            isRecoverable: true
        )
        for continuation in subscribers.values {
            await yield(.message(.failure(failure)), to: continuation)
        }
        discardWorker(intentional: true, clearReplayState: false)
        await handleUnexpectedWorkerStop(reason: failure.message)
    }

    func broadcastFailure(_ error: Error, code: String) async {
        let failure: SimulatorFailure
        if let simulatorFailure = error as? SimulatorFailure {
            failure = simulatorFailure
        } else if let controlError = error as? SimulatorControlError {
            failure = SimulatorFailure(
                code: controlError.code,
                message: controlError.message,
                isRecoverable: true
            )
        } else {
            failure = SimulatorFailure(code: code, message: String(describing: error), isRecoverable: true)
        }
        await broadcast(.message(.failure(failure)))
    }

    func yield(
        _ event: SimulatorWorkerEvent,
        to continuation: SimulatorWorkerEventStream.Continuation
    ) async {
        _ = await continuation.yield(event, byteCount: estimatedByteCount(of: event))
    }

    func estimatedByteCount(of event: SimulatorWorkerEvent) -> Int {
        switch event {
        case .workerStopped:
            return 1
        case let .message(message):
            return (try? JSONEncoder().encode(message).count) ?? 4_096
        }
    }
}
