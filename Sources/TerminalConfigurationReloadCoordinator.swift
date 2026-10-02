import Foundation

/// Serializes app-scoped Ghostty configuration replacement.
///
/// Requests that arrive while a transaction is preparing or reconciling are
/// merged into the next transaction. Their completions remain attached to that
/// transaction, so callers never observe success against an older config.
@MainActor
final class TerminalConfigurationReloadCoordinator {
    private(set) var phase:
        TerminalConfigurationReloadPhase = .idle
    private var pendingRequest:
        TerminalPendingConfigurationReload?
    private let maximumOutstandingCompletionCount: Int
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
    }

    var isReloadActive: Bool {
        phase == .preparing || phase == .reconciling
    }

    var isWaitingForFontWork: Bool {
        phase == .waitingForFontWork
    }

    /// Queues a request while bounding completion closures across the active
    /// and pending transactions. Reload semantics are retained even when
    /// excess completion closures are rejected.
    func enqueue(
        _ originalRequest: TerminalPendingConfigurationReload
    ) -> TerminalConfigurationReloadEnqueueResult {
        var request = originalRequest
        let requestedCompletionCount =
            request.completions.count
        let availableCompletionCount = max(
            0,
            maximumOutstandingCompletionCount
                - outstandingCompletionCount
        )
        let retainedCompletionCount = min(
            requestedCompletionCount,
            availableCompletionCount
        )
        if retainedCompletionCount
            < requestedCompletionCount {
            request.completions = Array(
                request.completions.prefix(
                    retainedCompletionCount
                )
            )
        }
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
            pendingRequest.completions.count
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
