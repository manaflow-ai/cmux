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
    /// A count-only scan is keyed by the visible count that caused it. The
    /// viewport snapshot can change on every render-grid frame while the
    /// artifact count stays the same; issuing another session RPC for those
    /// snapshots needlessly competes with terminal input and output traffic.
    private var lastRequestedLocalCount: Int?
    /// Refresh the authoritative count after a bounded run of unchanged
    /// render-grid generations so an artifact created outside the viewport is
    /// eventually reflected without reopening a scan for every frame.
    private var lastRequestedSurfaceGeneration: UInt64?
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
    static let maxDedupeSurfaceGenerationGap: UInt64 = 120

    mutating func reset() {
        stateGeneration &+= 1
        inFlight = nil
        trailing = nil
        lastRequestedLocalCount = nil
        lastRequestedSurfaceGeneration = nil
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
        let isWithinDedupeWindow: Bool
        if let requestedGeneration = lastRequestedSurfaceGeneration,
           surfaceGeneration >= requestedGeneration {
            isWithinDedupeWindow =
                surfaceGeneration - requestedGeneration < Self.maxDedupeSurfaceGenerationGap
        } else {
            isWithinDedupeWindow = false
        }
        if lastRequestedLocalCount == localCount, isWithinDedupeWindow {
            if inFlight != nil, trailing?.localCount == localCount {
                // Keep a queued count tied to the freshest render-grid
                // generation. The original request may settle after several
                // frames, and an old generation would otherwise discard the
                // follow-up as stale.
                trailing = pending
            }
            // Keep the chip's local observation current, but do not re-open
            // the count RPC until the visible count changes. A matching
            // trailing request still represents a count that has not been
            // scanned yet, so repeated render-grid observations must retain
            // it until the in-flight request completes.
            return .provisionalReport(provisional)
        }
        lastRequestedLocalCount = localCount
        lastRequestedSurfaceGeneration = surfaceGeneration
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
            // A queued observation was captured after the completed request,
            // but the caller's current render-grid snapshot can lag that
            // observation. Preserve the queued refresh whenever it is still
            // newer than the completed request, and pin it to the freshest
            // generation known by either side instead of dropping it on an
            // exact-generation mismatch.
            let trailingGenerationIsNewer =
                trailing.surfaceGeneration > request.surfaceGeneration
            let trailingCountChanged = trailing.localCount != request.localCount
            if trailing.surfaceGeneration >= request.surfaceGeneration,
               trailingGenerationIsNewer || trailingCountChanged {
                let nextRequest = makeRequest(Pending(
                    surfaceGeneration: max(
                        trailing.surfaceGeneration,
                        currentSurfaceGeneration
                    ),
                    localCount: trailing.localCount
                ))
                inFlight = nextRequest
                // The promoted request is now the request that dedupe must
                // compare against. A trailing observation may have a newer
                // generation than the last trigger marker, so leaving the
                // markers behind can reopen or suppress the wrong scan.
                lastRequestedLocalCount = nextRequest.localCount
                lastRequestedSurfaceGeneration = nextRequest.surfaceGeneration
                return Completion(outcome: outcome, nextRequest: nextRequest)
            }
        }

        if !scanSucceeded {
            // A failed request must not permanently claim this visible count.
            // Transient relay or RPC errors commonly leave the viewport
            // unchanged, including after a queued count briefly changed and
            // returned to the original value.
            lastRequestedLocalCount = nil
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
        lastRequestedLocalCount = nextRequest.localCount
        lastRequestedSurfaceGeneration = nextRequest.surfaceGeneration
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
