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

    func broadcast(_ event: SimulatorWorkerEvent, byteCount: Int? = nil) async {
        let chargedBytes = byteCount ?? estimatedByteCount(of: event)
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
