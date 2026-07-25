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
        /// A chip-only report while a session scan is already in flight.
        ///
        /// Provisional reports fire on every settled viewport change during
        /// streaming, so they must not fan out to gallery refresh listeners;
        /// only authoritative scan completions (and legacy `.report`) do.
        case provisionalReport(Report)
        /// Report a provisional count now and refine it with a session scan.
        ///
        /// The provisional report is what keeps the chip honest on a busy
        /// terminal: a session scan only survives if no output arrives while
        /// its RPC is in flight, so waiting for it systematically drops the
        /// positive counts (scanned right before the next output burst) while
        /// zero counts (scanned in quiet pauses) get through, parking the
        /// chip on zero and flickering it. The local count needs no RPC.
        case reportAndRequest(Report, Request)
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
    /// Last successful session total, held across transient scan failures so
    /// the chip does not regress to the viewport-only count (which oscillates
    /// while output streams) whenever one RPC drops.
    private var lastSessionTotal: Int?

    static let maxConsecutiveRearms = 3

    mutating func reset() {
        stateGeneration &+= 1
        inFlight = nil
        trailing = nil
        consecutiveRearmCount = 0
        lastSessionTotal = nil
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
        let provisional = Report(
            count: displayCount(forLocalCount: localCount),
            surfaceGeneration: surfaceGeneration
        )
        let pending = Pending(surfaceGeneration: surfaceGeneration, localCount: localCount)
        guard inFlight == nil else {
            trailing = pending
            return .provisionalReport(provisional)
        }
        let request = makeRequest(pending)
        inFlight = request
        return .reportAndRequest(provisional, request)
    }

    /// The count the chip should show for a fresh local scan: the last known
    /// session total wins while the session has artifacts, the viewport-only
    /// count otherwise.
    private func displayCount(forLocalCount localCount: Int) -> Int {
        if let lastSessionTotal, lastSessionTotal > 0 {
            return lastSessionTotal
        }
        return localCount
    }

    mutating func complete(
        _ request: Request,
        sessionTotal: Int?,
        currentSurfaceGeneration: UInt64,
        freshestLocalCount: Int
    ) -> Completion {
        guard request.stateGeneration == stateGeneration,
              inFlight == request else {
            return .stale
        }
        inFlight = nil

        let outcome: CompletionOutcome
        if request.surfaceGeneration == currentSurfaceGeneration {
            // Cache only accepted, current-generation responses: a dropped
            // response may belong to a superseded surface state (a generation
            // bump can coincide with a new agent session binding), and its
            // total must not seed provisional reports for the new one. The
            // re-armed request re-fetches under the current generation.
            if let sessionTotal {
                lastSessionTotal = sessionTotal
            }
            outcome = .reported(Report(
                count: displayCount(forLocalCount: request.localCount),
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
            localCount: freshestLocalCount
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
