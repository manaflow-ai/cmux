import Foundation
import CmuxTerminalCore
import os

/// Preserves terminal input order while Ghostty is resolving a clipboard read.
@MainActor
final class TerminalClipboardInputSequencer<Event, RequestID: Hashable & Sendable> {
    // Synchronous C callbacks reserve off-actor; this lock transfers their
    // bounded epoch, order, and overflow state to main-actor lifecycle work.
    private nonisolated let reservedAdmissions = OSAllocatedUnfairLock(
        initialState: ReservedAdmissionState()
    )
    private let maximumBufferedEvents: Int
    private var activeRequests: [RequestID: ActiveRequest] = [:]
    private var confirmationRequestIDs: Set<RequestID> = []
    private var initialCompletionRequestIDs: Set<RequestID> = []
    private var confirmedRequestIDs: Set<RequestID> = []
    private var buffersByEpoch: [UInt64: EpochBuffer] = [:]
    private var replayingEpochs: Set<UInt64> = []
    private var drainingCompletionEpochs: Set<UInt64> = []
    private var overflowCancellationDepthByEpoch: [UInt64: Int] = [:]
    private var deferredOverflowReplays: [(
        epoch: UInt64,
        replay: (Event) -> Void
    )] = []

    private let maximumBufferedCost: Int

    nonisolated init(
        maximumBufferedEvents: Int,
        maximumBufferedCost: Int = .max
    ) {
        self.maximumBufferedEvents = max(0, maximumBufferedEvents)
        self.maximumBufferedCost = max(0, maximumBufferedCost)
    }

    /// Marks a callback-issued request before its main-actor admission can run.
    @discardableResult
    nonisolated func reserveRequestAdmission(
        id: RequestID,
        epoch: UInt64 = 0,
        onOverflow: @escaping ReservedOverflowHandler
    ) -> Bool {
        reservedAdmissions.withLock { state in
            guard (state.overflowCancellationDepthByEpoch[epoch] ?? 0) == 0 else {
                return false
            }
            let order = state.nextOrder
            state.nextOrder &+= 1
            state.admissionsByID[id] = ReservedAdmission(
                epoch: epoch,
                order: order,
                overflowHandler: onOverflow
            )
            return true
        }
    }

    func beginRequest(
        id: RequestID,
        epoch: UInt64 = 0,
        onOverflow: @escaping () -> Void = {}
    ) {
        activeRequests[id] = ActiveRequest(
            epoch: epoch,
            defersInput: true,
            reservationOrder: nextRegistrationOrder(),
            onOverflow: onOverflow,
            readyCompletion: nil
        )
    }

    /// Tracks a non-paste clipboard request without blocking terminal input.
    func beginUnsequencedRequest(
        id: RequestID,
        epoch: UInt64
    ) {
        activeRequests[id] = ActiveRequest(
            epoch: epoch,
            defersInput: false,
            reservationOrder: nil,
            onOverflow: {},
            readyCompletion: nil
        )
    }

    /// Admits a request previously marked by ``reserveRequestAdmission()``.
    func beginReservedRequest(
        id: RequestID,
        onOverflow: @escaping () -> Void = {}
    ) {
        let admission = reservedAdmissions.withLock { state in
            state.admissionsByID.removeValue(forKey: id)
        }
        guard let admission else { return }
        activeRequests[id] = ActiveRequest(
            epoch: admission.epoch,
            defersInput: true,
            reservationOrder: admission.order,
            onOverflow: onOverflow,
            readyCompletion: nil
        )
    }

    /// Performs a prepared clipboard completion in request-registration order.
    ///
    /// Non-paste reads complete immediately. Reserved paste reads wait for
    /// every earlier reservation in the same runtime epoch, including a
    /// reservation whose main-actor admission has not run yet.
    func performCompletionWhenReady(
        id: RequestID,
        _ completion: @escaping () -> Void
    ) {
        guard var request = activeRequests[id] else {
            completion()
            return
        }
        guard request.reservationOrder != nil else {
            completion()
            return
        }
        guard request.readyCompletion == nil else { return }
        request.readyCompletion = completion
        activeRequests[id] = request
        drainReadyCompletions(for: request.epoch)
    }

    func requireConfirmation(for id: RequestID) {
        guard activeRequests[id] != nil else { return }
        confirmationRequestIDs.insert(id)
    }

    func shouldDefer(
        _ event: Event,
        epoch: UInt64 = 0,
        discardWhenFull: Bool = false,
        estimatedCost: Int = 1
    ) -> Bool {
        guard hasRequestInFlight(for: epoch) else { return false }

        let eventCost = max(0, estimatedCost)
        var buffer = buffersByEpoch[epoch] ?? EpochBuffer()
        while !hasCapacity(in: buffer, forEventCost: eventCost) {
            if discardWhenFull {
                return true
            }
            if let discardableIndex = buffer.events[
                buffer.nextEventIndex...
            ].firstIndex(where: \.discardWhenFull) {
                buffer.pendingCost -= buffer.events[discardableIndex]
                    .estimatedCost
                buffer.events.remove(at: discardableIndex)
            } else {
                let reservedOverflowHandlers = beginReservedOverflowCancellation(
                    for: epoch
                )
                let activeOverflowHandlers = activeRequests.compactMap {
                    id,
                    request -> OrderedOverflowHandler? in
                    guard request.epoch == epoch,
                          request.defersInput,
                          let order = request.reservationOrder else {
                        return nil
                    }
                    activeRequests[id]?.readyCompletion = nil
                    return OrderedOverflowHandler(
                        order: order,
                        action: .active(request.onOverflow)
                    )
                }
                let overflowHandlers = (
                    activeOverflowHandlers + reservedOverflowHandlers
                ).sorted { $0.order < $1.order }
                withOverflowCancellationBatch(for: epoch) {
                    overflowHandlers.forEach { $0.action.perform() }
                    endReservedOverflowCancellation(for: epoch)
                }
                guard hasRequestInFlight(for: epoch) else { return false }
                buffer = buffersByEpoch[epoch] ?? EpochBuffer()
                guard hasCapacity(in: buffer, forEventCost: eventCost) else {
                    // A cancellation handler that leaves its request active
                    // cannot preserve both boundedness and deferred order.
                    // Drop the retained prefix before failing open so it can
                    // never replay behind the current event.
                    buffersByEpoch.removeValue(forKey: epoch)
                    return false
                }
            }
        }
        buffer.events.append(
            BufferedEvent(
                event: event,
                discardWhenFull: discardWhenFull,
                estimatedCost: eventCost
            )
        )
        buffer.pendingCost += eventCost
        buffersByEpoch[epoch] = buffer
        return true
    }

    /// Returns whether a clipboard request is currently holding input for the
    /// given runtime epoch. Unsequenced reads intentionally return `false`.
    func hasInputDeferral(for epoch: UInt64 = 0) -> Bool {
        hasRequestInFlight(for: epoch)
    }

    /// Cancels a request whose native surface lifetime ended. Deferred input
    /// from that epoch is discarded without touching replacement-surface input.
    func cancelRequest(
        id: RequestID,
        currentEpoch: UInt64,
        deferredInputDisposition: RuntimeClipboardDeferredInputDisposition,
        replay: @escaping (Event) -> Void
    ) {
        guard let request = removeRequest(id: id) else { return }
        cancelBufferedInput(
            requestEpoch: request.epoch,
            currentEpoch: currentEpoch,
            disposition: deferredInputDisposition,
            replay: replay
        )
        drainReadyCompletions(for: request.epoch)
    }

    /// Consumes an admission that became stale before it could be associated
    /// with a request. Only input from the currently attached runtime survives.
    func cancelReservedRequest(
        id: RequestID,
        requestEpoch: UInt64,
        currentEpoch: UInt64,
        deferredInputDisposition: RuntimeClipboardDeferredInputDisposition,
        replay: @escaping (Event) -> Void
    ) {
        _ = reservedAdmissions.withLock { state in
            state.admissionsByID.removeValue(forKey: id)
        }
        cancelBufferedInput(
            requestEpoch: requestEpoch,
            currentEpoch: currentEpoch,
            disposition: deferredInputDisposition,
            replay: replay
        )
        drainReadyCompletions(for: requestEpoch)
    }

    func completeRequest(
        id: RequestID,
        confirmed: Bool,
        onLogicalCompletion: () -> Void = {},
        replay: @escaping (Event) -> Void
    ) {
        guard let request = activeRequests[id] else { return }
        if confirmed {
            confirmedRequestIDs.insert(id)
        } else {
            initialCompletionRequestIDs.insert(id)
        }
        if confirmationRequestIDs.contains(id) {
            guard initialCompletionRequestIDs.contains(id),
                  confirmedRequestIDs.contains(id) else {
                return
            }
        }

        _ = removeRequest(id: id)
        onLogicalCompletion()
        replayBufferedEvents(for: request.epoch, replay: replay)
        drainReadyCompletions(for: request.epoch)
    }

    private nonisolated func hasRequestAwaitingAdmission(
        for epoch: UInt64
    ) -> Bool {
        reservedAdmissions.withLock { state in
            state.admissionsByID.values.contains { $0.epoch == epoch }
        }
    }

    private nonisolated func earliestReservedAdmissionOrder(
        for epoch: UInt64
    ) -> UInt64? {
        reservedAdmissions.withLock { state in
            state.admissionsByID.values
                .filter { $0.epoch == epoch }
                .map(\.order)
                .min()
        }
    }

    private nonisolated func nextRegistrationOrder() -> UInt64 {
        reservedAdmissions.withLock { state in
            let order = state.nextOrder
            state.nextOrder &+= 1
            return order
        }
    }

    private func drainReadyCompletions(for epoch: UInt64) {
        guard drainingCompletionEpochs.insert(epoch).inserted else { return }
        defer { drainingCompletionEpochs.remove(epoch) }

        while true {
            let candidate = activeRequests.compactMap {
                id,
                request -> (id: RequestID, order: UInt64, completion: () -> Void)? in
                guard request.epoch == epoch,
                      let order = request.reservationOrder,
                      let completion = request.readyCompletion else {
                    return nil
                }
                return (id, order, completion)
            }.min { $0.order < $1.order }
            guard let candidate else { return }

            let earliestActiveOrder = activeRequests.values.compactMap {
                request -> UInt64? in
                guard request.epoch == epoch else { return nil }
                return request.reservationOrder
            }.min()
            let earliestWaitingOrder = earliestReservedAdmissionOrder(
                for: epoch
            )
            let earliestOrder = [earliestActiveOrder, earliestWaitingOrder]
                .compactMap { $0 }
                .min()
            guard earliestOrder == candidate.order else { return }

            activeRequests[candidate.id]?.readyCompletion = nil
            candidate.completion()
            guard activeRequests[candidate.id] == nil else { return }
        }
    }

    private func hasCapacity(
        in buffer: EpochBuffer,
        forEventCost eventCost: Int
    ) -> Bool {
        guard buffer.pendingCount < maximumBufferedEvents,
              buffer.pendingCost <= maximumBufferedCost else {
            return false
        }
        return eventCost <= maximumBufferedCost - buffer.pendingCost
    }

    private func beginReservedOverflowCancellation(
        for epoch: UInt64
    ) -> [OrderedOverflowHandler] {
        reservedAdmissions.withLock { state in
            state.overflowCancellationDepthByEpoch[epoch, default: 0] += 1
            let matchingAdmissions = state.admissionsByID.compactMap {
                id,
                admission -> (RequestID, ReservedAdmission)? in
                admission.epoch == epoch ? (id, admission) : nil
            }
            let handlers = matchingAdmissions.map { id, admission in
                state.admissionsByID.removeValue(forKey: id)
                return OrderedOverflowHandler(
                    order: admission.order,
                    action: .reserved(admission.overflowHandler)
                )
            }
            return handlers
        }
    }

    private func endReservedOverflowCancellation(for epoch: UInt64) {
        reservedAdmissions.withLock { state in
            let depth = state.overflowCancellationDepthByEpoch[epoch] ?? 0
            precondition(depth > 0)
            if depth == 1 {
                state.overflowCancellationDepthByEpoch.removeValue(
                    forKey: epoch
                )
            } else {
                state.overflowCancellationDepthByEpoch[epoch] = depth - 1
            }
        }
    }

    private func hasRequestInFlight(for epoch: UInt64) -> Bool {
        (overflowCancellationDepthByEpoch[epoch] ?? 0) > 0
            || activeRequests.values.contains(where: {
                $0.epoch == epoch && $0.defersInput
            })
            || hasRequestAwaitingAdmission(for: epoch)
    }

    /// Keeps replay closed until every overflowing request has been cancelled.
    private func withOverflowCancellationBatch(
        for epoch: UInt64,
        _ body: () -> Void
    ) {
        overflowCancellationDepthByEpoch[epoch, default: 0] += 1
        body()
        let depth = overflowCancellationDepthByEpoch[epoch] ?? 0
        precondition(depth > 0)
        if depth == 1 {
            overflowCancellationDepthByEpoch.removeValue(forKey: epoch)
        } else {
            overflowCancellationDepthByEpoch[epoch] = depth - 1
        }
        guard depth == 1 else { return }

        let matchingReplays = deferredOverflowReplays.filter {
            $0.epoch == epoch
        }
        deferredOverflowReplays.removeAll { $0.epoch == epoch }
        for deferredReplay in matchingReplays {
            replayBufferedEvents(
                for: deferredReplay.epoch,
                replay: deferredReplay.replay
            )
        }
    }

    private func removeRequest(id: RequestID) -> ActiveRequest? {
        guard let request = activeRequests.removeValue(forKey: id) else {
            return nil
        }
        confirmationRequestIDs.remove(id)
        initialCompletionRequestIDs.remove(id)
        confirmedRequestIDs.remove(id)
        return request
    }

    private func cancelBufferedInput(
        requestEpoch: UInt64,
        currentEpoch: UInt64,
        disposition: RuntimeClipboardDeferredInputDisposition,
        replay: @escaping (Event) -> Void
    ) {
        switch disposition {
        case .replay:
            replayBufferedEvents(for: requestEpoch, replay: replay)
        case .discard:
            buffersByEpoch.removeValue(forKey: requestEpoch)
            guard currentEpoch != requestEpoch else { return }
            replayBufferedEvents(for: currentEpoch, replay: replay)
        }
    }

    private func replayBufferedEvents(
        for epoch: UInt64,
        replay: @escaping (Event) -> Void
    ) {
        if (overflowCancellationDepthByEpoch[epoch] ?? 0) > 0 {
            deferredOverflowReplays.append((epoch, replay))
            return
        }
        guard !hasRequestInFlight(for: epoch),
              replayingEpochs.insert(epoch).inserted else {
            return
        }
        defer {
            replayingEpochs.remove(epoch)
            if var buffer = buffersByEpoch[epoch] {
                if buffer.nextEventIndex == buffer.events.count {
                    buffersByEpoch.removeValue(forKey: epoch)
                } else if buffer.nextEventIndex > 0 {
                    buffer.events.removeFirst(buffer.nextEventIndex)
                    buffer.nextEventIndex = 0
                    buffersByEpoch[epoch] = buffer
                }
            }
        }

        while !hasRequestInFlight(for: epoch),
              var buffer = buffersByEpoch[epoch],
              buffer.nextEventIndex < buffer.events.count {
            let event = buffer.events[buffer.nextEventIndex].event
            buffer.pendingCost -= buffer.events[buffer.nextEventIndex]
                .estimatedCost
            buffer.nextEventIndex += 1
            buffersByEpoch[epoch] = buffer
            replay(event)
        }
    }
}
