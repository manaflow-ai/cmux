import Foundation

/// Serializes app-scoped Ghostty configuration replacement.
///
/// Requests that arrive while a transaction is preparing or reconciling are
/// merged into the next transaction. Their callbacks remain attached to that
/// transaction, so callers never observe success against an older config.
@MainActor
final class TerminalConfigurationReloadCoordinator {
    private(set) var phase:
        TerminalConfigurationReloadPhase = .idle
    private var pendingRequest:
        TerminalPendingConfigurationReload?
    private let maximumOutstandingCompletionCount: Int
    // Keep one slot available for a latency-sensitive commit acknowledgement;
    // post-fanout callbacks are optional and may be rejected at the boundary.
    private let reservedCommitCompletionCapacity: Int
    private var outstandingCompletionCount = 0
    private var activeCompletionCount = 0

    nonisolated init(
        maximumOutstandingCompletionCount: Int = 32
    ) {
        precondition(
            maximumOutstandingCompletionCount > 0,
            "Configuration reload completion capacity must be positive"
        )
        self.maximumOutstandingCompletionCount =
            maximumOutstandingCompletionCount
        self.reservedCommitCompletionCapacity =
            maximumOutstandingCompletionCount > 0 ? 1 : 0
    }

    var isReloadActive: Bool {
        phase == .preparing || phase == .reconciling
    }

    var isWaitingForFontWork: Bool {
        phase == .waitingForFontWork
    }

    /// Queues a request while bounding commit and post-fanout callbacks across
    /// the active and pending transactions. Reload semantics are retained even
    /// when excess callbacks are rejected.
    func enqueue(
        _ originalRequest: TerminalPendingConfigurationReload
    ) -> TerminalConfigurationReloadEnqueueResult {
        var request = originalRequest
        let requestedCompletionCount =
            request.totalCompletionCount
        let availableCompletionCount = max(
            0,
            maximumOutstandingCompletionCount
                - outstandingCompletionCount
        )
        // Commit acknowledgements are the latency-sensitive socket path, so
        // retain them before optional post-fanout callbacks. For
        // completion-only requests, keep one slot reserved so a later commit
        // acknowledgement is not silently dropped behind optional work. A
        // request that already carries commit callbacks may consume the
        // remaining capacity; later requests then receive normal bounded
        // backpressure rather than exceeding the global limit.
        let retainedCommitCompletionCount = min(
            request.commitCompletions.count,
            availableCompletionCount
        )
        let availableForFinalCompletions = max(
            0,
            availableCompletionCount
                - retainedCommitCompletionCount
                - (request.commitCompletions.isEmpty
                    ? reservedCommitCompletionCapacity
                    : 0)
        )
        let retainedFinalCompletionCount = min(
            request.completions.count,
            availableForFinalCompletions
        )
        let retainedCompletionCount =
            retainedCommitCompletionCount + retainedFinalCompletionCount
        request.commitCompletions = Array(
            request.commitCompletions.prefix(
                retainedCommitCompletionCount
            )
        )
        request.completions = Array(
            request.completions.prefix(
                retainedFinalCompletionCount
            )
        )
        outstandingCompletionCount +=
            retainedCompletionCount

        if var pendingRequest {
            pendingRequest.merge(request)
            self.pendingRequest = pendingRequest
        } else {
            pendingRequest = request
        }

        let needsFontWorkBarrier = phase == .idle
        if needsFontWorkBarrier {
            phase = .waitingForFontWork
        }
        return TerminalConfigurationReloadEnqueueResult(
            needsFontWorkBarrier: needsFontWorkBarrier,
            rejectedCompletionCount:
                requestedCompletionCount
                - retainedCompletionCount
        )
    }

    /// Starts the transaction admitted by the current font-work barrier.
    func takePendingRequest()
        -> TerminalPendingConfigurationReload? {
        precondition(
            phase == .waitingForFontWork,
            "Configuration reload must wait for font work"
        )
        guard let pendingRequest else {
            phase = .idle
            return nil
        }
        self.pendingRequest = nil
        precondition(
            activeCompletionCount == 0,
            "Only one configuration reload can be active"
        )
        activeCompletionCount =
            pendingRequest.totalCompletionCount
        phase = .preparing
        return pendingRequest
    }

    func beginReconciliation() {
        precondition(
            phase == .preparing,
            "Configuration reconciliation must follow preparation"
        )
        phase = .reconciling
    }

    /// Finishes the active transaction and returns whether queued requests
    /// need the next font-work barrier scheduled.
    func finishReload() -> Bool {
        precondition(
            phase == .preparing || phase == .reconciling,
            "Only an active configuration reload can finish"
        )
        precondition(
            activeCompletionCount
                <= outstandingCompletionCount,
            "Active completions must be part of the outstanding total"
        )
        outstandingCompletionCount -=
            activeCompletionCount
        activeCompletionCount = 0
        guard pendingRequest != nil else {
            phase = .idle
            return false
        }
        phase = .waitingForFontWork
        return true
    }
}
