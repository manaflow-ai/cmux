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

    struct Completion: Sendable, Equatable {
        let report: Report?
        let nextRequest: Request?

        static let stale = Completion(report: nil, nextRequest: nil)
    }

    private struct Pending: Sendable, Equatable {
        let surfaceGeneration: UInt64
        let localCount: Int
    }

    private var stateGeneration: UInt64 = 0
    private var inFlight: Request?
    private var trailing: Pending?

    mutating func reset() {
        stateGeneration &+= 1
        inFlight = nil
        trailing = nil
    }

    mutating func trigger(
        localCount: Int,
        surfaceGeneration: UInt64,
        supportsSessionCount: Bool
    ) -> TriggerAction {
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

        let report = request.surfaceGeneration == currentSurfaceGeneration
            ? Report(
                count: sessionTotal ?? request.localCount,
                surfaceGeneration: request.surfaceGeneration
            )
            : nil

        guard let trailing else {
            return Completion(report: report, nextRequest: nil)
        }
        self.trailing = nil
        guard trailing.surfaceGeneration == currentSurfaceGeneration else {
            return Completion(report: report, nextRequest: nil)
        }
        let nextRequest = makeRequest(trailing)
        inFlight = nextRequest
        return Completion(report: report, nextRequest: nextRequest)
    }

    private func makeRequest(_ pending: Pending) -> Request {
        Request(
            stateGeneration: stateGeneration,
            surfaceGeneration: pending.surfaceGeneration,
            localCount: pending.localCount
        )
    }
}
