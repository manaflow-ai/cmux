import Foundation

/// Preserves terminal input order while Ghostty is resolving a clipboard read.
@MainActor
final class TerminalClipboardInputSequencer<Event, RequestID: Hashable> {
    enum Routing: Equatable {
        case dispatchNow
        case queued
        case rejected
    }

    private let maximumBufferedEvents: Int
    private var activeRequestIDs: Set<RequestID> = []
    private var confirmationRequestIDs: Set<RequestID> = []
    private var initialCompletionRequestIDs: Set<RequestID> = []
    private var confirmedRequestIDs: Set<RequestID> = []
    private var bufferedEvents: [Event] = []
    private var nextBufferedEventIndex = 0
    private var isReplaying = false

    init(maximumBufferedEvents: Int) {
        self.maximumBufferedEvents = max(0, maximumBufferedEvents)
    }

    func beginRequest(id: RequestID) {
        activeRequestIDs.insert(id)
    }

    func requireConfirmation(for id: RequestID) {
        guard activeRequestIDs.contains(id) else { return }
        confirmationRequestIDs.insert(id)
    }

    func route(_ event: Event) -> Routing {
        guard !isReplaying else { return .dispatchNow }
        guard !activeRequestIDs.isEmpty else { return .dispatchNow }
        guard bufferedEventCount < maximumBufferedEvents else {
            return .rejected
        }
        bufferedEvents.append(event)
        return .queued
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
        replayBufferedEventsIfPossible(replay)
    }

    private var bufferedEventCount: Int {
        bufferedEvents.count - nextBufferedEventIndex
    }

    private func replayBufferedEventsIfPossible(_ replay: (Event) -> Void) {
        guard activeRequestIDs.isEmpty, !isReplaying else { return }
        isReplaying = true
        defer {
            isReplaying = false
            if nextBufferedEventIndex == bufferedEvents.count {
                bufferedEvents.removeAll(keepingCapacity: true)
                nextBufferedEventIndex = 0
            }
        }

        while activeRequestIDs.isEmpty,
              nextBufferedEventIndex < bufferedEvents.count {
            let event = bufferedEvents[nextBufferedEventIndex]
            nextBufferedEventIndex += 1
            replay(event)
        }
    }
}
