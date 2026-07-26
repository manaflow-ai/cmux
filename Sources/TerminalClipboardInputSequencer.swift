import CmuxFoundation
import Foundation

/// Preserves terminal input order while Ghostty is resolving a clipboard read.
@MainActor
final class TerminalClipboardInputSequencer<Event, RequestID: Hashable> {
    private nonisolated let reservedRequestAdmissionCount =
        AtomicUInt64Generation()
    private nonisolated let admittedRequestAdmissionCount =
        AtomicUInt64Generation()
    private let maximumBufferedEvents: Int
    private var activeRequestIDs: Set<RequestID> = []
    private var confirmationRequestIDs: Set<RequestID> = []
    private var initialCompletionRequestIDs: Set<RequestID> = []
    private var confirmedRequestIDs: Set<RequestID> = []
    private var bufferedEvents: [Event] = []
    private var nextBufferedEventIndex = 0
    private var isReplaying = false

    nonisolated init(maximumBufferedEvents: Int) {
        self.maximumBufferedEvents = max(0, maximumBufferedEvents)
    }

    /// Marks a callback-issued request before its main-actor admission can run.
    nonisolated func reserveRequestAdmission() {
        _ = reservedRequestAdmissionCount.advanceRelease()
    }

    func beginRequest(id: RequestID) {
        activeRequestIDs.insert(id)
    }

    /// Admits a request previously marked by ``reserveRequestAdmission()``.
    func beginReservedRequest(id: RequestID) {
        activeRequestIDs.insert(id)
        _ = admittedRequestAdmissionCount.advanceRelease()
    }

    func requireConfirmation(for id: RequestID) {
        guard activeRequestIDs.contains(id) else { return }
        confirmationRequestIDs.insert(id)
    }

    func shouldDefer(
        _ event: Event,
        replay: (Event) -> Void = { _ in }
    ) -> Bool {
        guard !isReplaying else { return false }
        guard hasRequestInFlight else { return false }
        guard bufferedEventCount < maximumBufferedEvents else {
            // Key-up and flags-changed events cannot be dropped without
            // leaving terminal keyboard state stuck, and this synchronous
            // AppKit callback cannot wait without blocking the UI. At the
            // emergency bound, fail open by replaying accepted events in FIFO
            // order before routing the current event normally.
            replayBufferedEvents(
                replay,
                whileRequestsAreActive: true
            )
            return false
        }
        bufferedEvents.append(event)
        return true
    }

    func completeRequest(
        id: RequestID,
        confirmed: Bool,
        replay: (Event) -> Void
    ) {
        guard activeRequestIDs.contains(id) else { return }
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

        activeRequestIDs.remove(id)
        confirmationRequestIDs.remove(id)
        initialCompletionRequestIDs.remove(id)
        confirmedRequestIDs.remove(id)
        replayBufferedEvents(replay)
    }

    private var bufferedEventCount: Int {
        bufferedEvents.count - nextBufferedEventIndex
    }

    private var hasRequestInFlight: Bool {
        !activeRequestIDs.isEmpty || hasRequestAwaitingAdmission
    }

    private nonisolated var hasRequestAwaitingAdmission: Bool {
        // Read admitted first so an admission racing these loads can only cause
        // a harmless extra deferral, never let post-paste input overtake paste.
        let admitted = admittedRequestAdmissionCount.loadAcquire()
        let reserved = reservedRequestAdmissionCount.loadAcquire()
        return admitted < reserved
    }

    private func replayBufferedEvents(
        _ replay: (Event) -> Void,
        whileRequestsAreActive: Bool = false
    ) {
        guard (whileRequestsAreActive || !hasRequestInFlight),
              !isReplaying else {
            return
        }
        isReplaying = true
        defer {
            isReplaying = false
            if nextBufferedEventIndex == bufferedEvents.count {
                bufferedEvents.removeAll(keepingCapacity: true)
                nextBufferedEventIndex = 0
            }
        }

        while (whileRequestsAreActive || !hasRequestInFlight),
              nextBufferedEventIndex < bufferedEvents.count {
            let event = bufferedEvents[nextBufferedEventIndex]
            nextBufferedEventIndex += 1
            replay(event)
        }
    }
}
