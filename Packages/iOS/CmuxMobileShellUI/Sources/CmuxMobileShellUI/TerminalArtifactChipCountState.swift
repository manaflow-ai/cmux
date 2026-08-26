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
    /// Last successful gallery total (or positive legacy session total), held
    /// across transient scan failures so
    /// the chip does not regress to the viewport-only count (which oscillates
    /// while output streams) whenever one RPC drops.
    private var lastAuthoritativeTotal: Int?
    /// Session the held total belongs to. A terminal can bind a new agent
    /// session without remounting the coordinator, and its first count-only
    /// responses can carry the new session's ID with no total yet — the held
    /// total from the previous session must be invalidated then, not shown.
    private var lastAuthoritativeSessionID: String?

    static let maxConsecutiveRearms = 3

    mutating func reset() {
        stateGeneration &+= 1
        inFlight = nil
        trailing = nil
        consecutiveRearmCount = 0
        lastAuthoritativeTotal = nil
        lastAuthoritativeSessionID = nil
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
    /// authoritative total wins when one exists, the viewport-only count
    /// otherwise.
    private func displayCount(forLocalCount localCount: Int) -> Int {
        if let lastAuthoritativeTotal {
            return lastAuthoritativeTotal
        }
        return localCount
    }

    mutating func complete(
        _ request: Request,
        galleryRowTotal: Int? = nil,
        sessionTotal: Int?,
        sessionID: String? = nil,
        scanSucceeded: Bool = true,
        currentSurfaceGeneration: UInt64,
        freshestLocalCount: Int
    ) -> Completion {
        guard request.stateGeneration == stateGeneration,
              inFlight == request else {
            return .stale
        }
        inFlight = nil
        if let sessionID, sessionID != lastAuthoritativeSessionID {
            // Session identity is generation-independent: any response naming
            // a different session proves the binding changed, even when its
            // count is stale for the current viewport (during streaming most
            // responses are). Invalidate the old session's total here; totals
            // themselves are cached only from accepted responses below.
            lastAuthoritativeTotal = nil
            lastAuthoritativeSessionID = sessionID
        } else if scanSucceeded, sessionID == nil, lastAuthoritativeSessionID != nil {
            // A SUCCESSFUL response with no session means the binding is gone
            // (e.g. the session moved to another surface) — unlike a transport
            // failure, which proves nothing and holds. Clear the stale total.
            lastAuthoritativeTotal = nil
            lastAuthoritativeSessionID = nil
        }

        let outcome: CompletionOutcome
        if request.surfaceGeneration == currentSurfaceGeneration {
            // Cache only accepted, current-generation responses: a dropped
            // response's total may be stale for the superseded surface state
            // and must not seed provisional reports. The re-armed request
            // re-fetches under the current generation.
            if let galleryRowTotal {
                lastAuthoritativeTotal = galleryRowTotal
                lastAuthoritativeSessionID = sessionID ?? lastAuthoritativeSessionID
            } else if let sessionTotal {
                // Preserve the old-Mac behavior exactly: positive Session
                // totals win, while zero falls back to the local viewport count.
                lastAuthoritativeTotal = sessionTotal > 0 ? sessionTotal : nil
                lastAuthoritativeSessionID = sessionID ?? lastAuthoritativeSessionID
            } else if lastAuthoritativeTotal == 0, request.localCount > 0 {
                // The scan FAILED while fresh local evidence says files are on
                // screen. A held zero must not keep the chip unmounted until
                // the transport recovers; drop it so the local count shows
                // (and stays shown across subsequent failed scans) until a
                // successful scan re-establishes the authoritative total.
                lastAuthoritativeTotal = nil
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
