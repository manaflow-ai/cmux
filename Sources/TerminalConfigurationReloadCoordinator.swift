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

    nonisolated init() {}

    var isReloadActive: Bool {
        phase == .preparing || phase == .reconciling
    }

    var isWaitingForFontWork: Bool {
        phase == .waitingForFontWork
    }

    /// Queues a request and returns whether its idle-to-waiting transition
    /// needs a font-work barrier scheduled.
    func enqueue(
        _ request: TerminalPendingConfigurationReload
    ) -> Bool {
        if var pendingRequest {
            pendingRequest.merge(request)
            self.pendingRequest = pendingRequest
        } else {
            pendingRequest = request
        }
        guard phase == .idle else { return false }
        phase = .waitingForFontWork
        return true
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
        guard pendingRequest != nil else {
            phase = .idle
            return false
        }
        phase = .waitingForFontWork
        return true
    }
}
