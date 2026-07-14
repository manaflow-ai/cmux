import Foundation

/// Coalesces session-count requests while preserving the local visible-count fallback.
struct TerminalArtifactChipCountState: Sendable {
    struct Request: Sendable, Equatable {
        let stateGeneration: UInt64
        let surfaceGeneration: UInt64
        let localCount: Int
    }

    struct Report: Sendable, Equatable {
        let count: Int
        let surfaceGeneration: UInt64
    }

    enum TriggerAction: Sendable, Equatable {
        case none
        case report(Report)
        case request(Request)
    }

    enum CompletionOutcome: Sendable, Equatable {
        case reported(Report)
        case droppedForSurfaceGenerationMismatch
        case stale
    }

    struct Completion: Sendable, Equatable {
        let outcome: CompletionOutcome
        let nextRequest: Request?

        static let stale = Completion(outcome: .stale, nextRequest: nil)
    }

    private struct Pending: Sendable, Equatable {
        let surfaceGeneration: UInt64
        let localCount: Int
    }

    private var stateGeneration: UInt64 = 0
    private var inFlight: Request?
    private var trailing: Pending?
    private var consecutiveRearmCount = 0

    static let maxConsecutiveRearms = 3

    mutating func reset() {
        stateGeneration &+= 1
        inFlight = nil
        trailing = nil
        consecutiveRearmCount = 0
    }

    mutating func trigger(
        localCount: Int,
        surfaceGeneration: UInt64,
        supportsSessionCount: Bool
    ) -> TriggerAction {
        consecutiveRearmCount = 0
        guard supportsSessionCount else {
            return .report(Report(count: localCount, surfaceGeneration: surfaceGeneration))
        }
        let pending = Pending(surfaceGeneration: surfaceGeneration, localCount: localCount)
        guard inFlight == nil else {
            trailing = pending
            return .none
        }
        let request = makeRequest(pending)
        inFlight = request
        return .request(request)
    }

    mutating func complete(
        _ request: Request,
        sessionTotal: Int?,
        currentSurfaceGeneration: UInt64
    ) -> Completion {
        guard request.stateGeneration == stateGeneration,
              inFlight == request else {
            return .stale
        }
        inFlight = nil

        let outcome: CompletionOutcome
        if request.surfaceGeneration == currentSurfaceGeneration {
            let count = sessionTotal.map { $0 > 0 ? $0 : request.localCount }
                ?? request.localCount
            outcome = .reported(Report(
                count: count,
                surfaceGeneration: request.surfaceGeneration
            ))
            consecutiveRearmCount = 0
        } else {
            outcome = .droppedForSurfaceGenerationMismatch
        }

        if let trailing {
            self.trailing = nil
            if trailing.surfaceGeneration == currentSurfaceGeneration {
                let nextRequest = makeRequest(trailing)
                inFlight = nextRequest
                return Completion(outcome: outcome, nextRequest: nextRequest)
            }
        }

        guard outcome == .droppedForSurfaceGenerationMismatch,
              consecutiveRearmCount < Self.maxConsecutiveRearms else {
            return Completion(outcome: outcome, nextRequest: nil)
        }
        consecutiveRearmCount += 1
        let nextRequest = makeRequest(Pending(
            surfaceGeneration: currentSurfaceGeneration,
            localCount: request.localCount
        ))
        inFlight = nextRequest
        return Completion(outcome: outcome, nextRequest: nextRequest)
    }

    private func makeRequest(_ pending: Pending) -> Request {
        Request(
            stateGeneration: stateGeneration,
            surfaceGeneration: pending.surfaceGeneration,
            localCount: pending.localCount
        )
    }
}
