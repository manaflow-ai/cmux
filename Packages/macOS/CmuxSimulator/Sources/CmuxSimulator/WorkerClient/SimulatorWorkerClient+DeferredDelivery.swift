import Foundation

extension SimulatorWorkerClient {
    func prepareRetryAfterTransportFailure(
        _ error: Error,
        attempt: Int,
        beginsAttachment: Bool
    ) async throws {
        discardWorker(intentional: true, clearReplayState: false)
        if attempt == 0, !restartAttemptUsed {
            restartAttemptUsed = true
            return
        }
        await tripCrashFuse(reason: error)
        if beginsAttachment { attachmentAwaitingStreaming = false }
        throw SimulatorControlError(
            code: "worker_unavailable",
            arguments: arguments,
            message: String.localizedStringWithFormat(
                String(
                    localized: "simulator.failure.workerCommandRejected",
                    defaultValue: "The isolated Simulator worker could not accept a command: %@"
                ),
                String(describing: error)
            )
        )
    }

    func shouldDeferMessage(_ message: SimulatorWorkerInbound) -> Bool {
        switch message {
        case .shutdown, .releaseInputs, .acknowledgeFrameTransport:
            return false
        default:
            return attachmentAwaitingStreaming
                || replayIsActive
                || !pendingTextInputUsages.isEmpty
                || !pendingInteractiveRequestIdentifiers.isEmpty
                || pendingPingSequence != nil
        }
    }

    func deferMessageUntilDelivered(_ message: SimulatorWorkerInbound) async throws {
        guard let requestIdentifier = message.requestIdentifier else {
            try enqueueDeferredMessage(message)
            return
        }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    guard deferredRequestDeliveries[requestIdentifier] == nil else {
                        throw SimulatorControlError(
                            code: "duplicate_worker_request",
                            arguments: [],
                            message: String(
                                localized: "simulator.failure.duplicateWorkerRequest",
                                defaultValue: "A Simulator worker request reused an active correlation identifier."
                            )
                        )
                    }
                    try enqueueDeferredMessage(message)
                    deferredRequestDeliveries[requestIdentifier] = continuation
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancelDeferredRequest(requestIdentifier) }
        }
    }

    func enqueueDeferredMessage(_ message: SimulatorWorkerInbound) throws {
        var deferredMessage = message
        if case .resize = message {
            deferredMessages.removeAll { if case .resize = $0 { true } else { false } }
        } else if case let .pointer(event) = message, event.phase == .moved {
            deferredMessages.removeAll {
                if case let .pointer(event) = $0, event.phase == .moved { true } else { false }
            }
        } else if case let .scrollWheel(event) = message,
                  let existingIndex = deferredMessages.firstIndex(where: {
                      if case .scrollWheel = $0 { true } else { false }
                  }),
                  case let .scrollWheel(existing) = deferredMessages.remove(at: existingIndex) {
            let deltaX = existing.deltaX + event.deltaX
            let deltaY = existing.deltaY + event.deltaY
            guard deltaX != 0 || deltaY != 0 else { return }
            deferredMessage = .scrollWheel(SimulatorScrollWheelEvent(
                id: event.id,
                anchor: existing.anchor,
                deltaX: deltaX,
                deltaY: deltaY
            ))
        }
        guard deferredMessages.count < SimulatorLengthPrefixedMessageChannel.maximumBufferedFrameCount
        else {
            throw SimulatorControlError(
                code: "worker_input_queue_busy",
                arguments: [],
                message: String(
                    localized: "simulator.failure.workerInputQueueBusy",
                    defaultValue: "The Simulator input queue is at capacity."
                )
            )
        }
        deferredMessages.append(deferredMessage)
    }

    func completeDeferredDelivery(for message: SimulatorWorkerInbound) {
        guard let requestIdentifier = message.requestIdentifier else { return }
        deferredRequestDeliveries.removeValue(forKey: requestIdentifier)?.resume()
    }

    func failDeferredDelivery(
        for message: SimulatorWorkerInbound,
        with failure: SimulatorFailure
    ) {
        guard let requestIdentifier = message.requestIdentifier else { return }
        deferredRequestDeliveries.removeValue(forKey: requestIdentifier)?.resume(throwing: failure)
    }

    func failDeferredDeliveries(with failure: SimulatorFailure) {
        let continuations = deferredRequestDeliveries.values
        deferredRequestDeliveries.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: failure)
        }
    }

    func cancelDeferredRequest(_ requestIdentifier: UUID) {
        guard let continuation = deferredRequestDeliveries.removeValue(forKey: requestIdentifier)
        else { return }
        deferredMessages.removeAll { $0.requestIdentifier == requestIdentifier }
        continuation.resume(throwing: CancellationError())
    }
}
