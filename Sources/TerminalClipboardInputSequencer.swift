import Foundation
import os

/// Preserves terminal input order while Ghostty is resolving a clipboard read.
@MainActor
final class TerminalClipboardInputSequencer<Event, RequestID: Hashable & Sendable> {
    typealias ReservedOverflowHandler = @MainActor @Sendable () -> Void

    private struct ReservedAdmissionState: Sendable {
        var overflowHandlersByID: [RequestID: ReservedOverflowHandler] = [:]
    }

    private struct BufferedEvent {
        let event: Event
        let discardWhenFull: Bool
    }

    private struct EpochBuffer {
        var events: [BufferedEvent] = []
        var nextEventIndex = 0

        var pendingCount: Int {
            events.count - nextEventIndex
        }
    }

    private struct ActiveRequest {
        let epoch: UInt64
        let onOverflow: () -> Void
    }

    // Synchronous C callbacks reserve off-actor; this lock only transfers their
    // bounded overflow handlers to main-actor admission and cancellation.
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

    nonisolated init(maximumBufferedEvents: Int) {
        self.maximumBufferedEvents = max(0, maximumBufferedEvents)
    }

    /// Marks a callback-issued request before its main-actor admission can run.
    nonisolated func reserveRequestAdmission(
        id: RequestID,
        onOverflow: @escaping ReservedOverflowHandler
    ) {
        reservedAdmissions.withLock { state in
            state.overflowHandlersByID[id] = onOverflow
        }
    }

    func beginRequest(
        id: RequestID,
        epoch: UInt64 = 0,
        onOverflow: @escaping () -> Void = {}
    ) {
        activeRequests[id] = ActiveRequest(
            epoch: epoch,
            onOverflow: onOverflow
        )
    }

    /// Admits a request previously marked by ``reserveRequestAdmission()``.
    func beginReservedRequest(
        id: RequestID,
        epoch: UInt64 = 0,
        onOverflow: @escaping () -> Void = {}
    ) {
        let hadReservation = reservedAdmissions.withLock { state in
            state.overflowHandlersByID.removeValue(forKey: id) != nil
        }
        guard hadReservation else { return }
        activeRequests[id] = ActiveRequest(
            epoch: epoch,
            onOverflow: onOverflow
        )
    }

    func requireConfirmation(for id: RequestID) {
        guard activeRequests[id] != nil else { return }
        confirmationRequestIDs.insert(id)
    }

    func shouldDefer(
        _ event: Event,
        epoch: UInt64 = 0,
        discardWhenFull: Bool = false
    ) -> Bool {
        guard !replayingEpochs.contains(epoch) else { return false }
        guard hasRequestInFlight(for: epoch) else { return false }

        var buffer = buffersByEpoch[epoch] ?? EpochBuffer()
        if buffer.pendingCount >= maximumBufferedEvents {
            if discardWhenFull {
                return true
            }
            if let discardableIndex = buffer.events[
                buffer.nextEventIndex...
            ].firstIndex(where: \.discardWhenFull) {
                buffer.events.remove(at: discardableIndex)
            } else {
                let activeOverflowHandlers = activeRequests.values
                    .filter { $0.epoch == epoch }
                    .map(\.onOverflow)
                let reservedOverflowHandlers = takeReservedOverflowHandlers()
                activeOverflowHandlers.forEach { $0() }
                reservedOverflowHandlers.forEach { $0() }
                return hasRequestInFlight(for: epoch)
            }
        }
        buffer.events.append(
            BufferedEvent(
                event: event,
                discardWhenFull: discardWhenFull
            )
        )
        buffersByEpoch[epoch] = buffer
        return true
    }

    /// Cancels a request whose native surface lifetime ended. Deferred input
    /// from that epoch is discarded without touching replacement-surface input.
    func cancelRequest(
        id: RequestID,
        currentEpoch: UInt64,
        replay: (Event) -> Void
    ) {
        guard let request = removeRequest(id: id) else { return }
        buffersByEpoch.removeValue(forKey: request.epoch)
        replayBufferedEvents(for: currentEpoch, replay: replay)
    }

    /// Consumes an admission that became stale before it could be associated
    /// with a request. Only input from the currently attached runtime survives.
    func cancelReservedRequest(
        id: RequestID,
        currentEpoch: UInt64,
        replay: (Event) -> Void
    ) {
        _ = reservedAdmissions.withLock { state in
            state.overflowHandlersByID.removeValue(forKey: id)
        }
        buffersByEpoch = buffersByEpoch.filter { epoch, _ in
            epoch == currentEpoch
        }
        replayBufferedEvents(for: currentEpoch, replay: replay)
    }

    func completeRequest(
        id: RequestID,
        confirmed: Bool,
        replay: (Event) -> Void
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
        replayBufferedEvents(for: request.epoch, replay: replay)
    }

    private nonisolated var hasRequestAwaitingAdmission: Bool {
        reservedAdmissions.withLock { state in
            !state.overflowHandlersByID.isEmpty
        }
    }

    private func takeReservedOverflowHandlers() -> [ReservedOverflowHandler] {
        reservedAdmissions.withLock { state in
            let handlers = Array(state.overflowHandlersByID.values)
            state.overflowHandlersByID.removeAll(keepingCapacity: false)
            return handlers
        }
    }

    private func hasRequestInFlight(for epoch: UInt64) -> Bool {
        activeRequests.values.contains(where: { $0.epoch == epoch })
            || hasRequestAwaitingAdmission
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

    private func replayBufferedEvents(
        for epoch: UInt64,
        replay: (Event) -> Void
    ) {
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
            buffer.nextEventIndex += 1
            buffersByEpoch[epoch] = buffer
            replay(event)
        }
    }
}
