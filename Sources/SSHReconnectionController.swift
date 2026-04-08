import Foundation

/// Manages SSH auto-reconnection for terminal panels whose child process (SSH) exited unexpectedly.
///
/// When a terminal panel running SSH disconnects, instead of closing the panel immediately,
/// this controller schedules reconnection attempts with exponential backoff. The old panel
/// is kept alive (preserving scrollback) until the new terminal is created.
@MainActor
final class SSHReconnectionController {

    struct PendingReconnection {
        let sshCommand: String
        let destination: String
        let oldPanelId: UUID
        var retryCount: Int
        var workItem: DispatchWorkItem?
        let startedAt: Date
    }

    static let maxRetries = 5
    static let baseDelay: TimeInterval = 1.0
    static let maxDelay: TimeInterval = 30.0

    private var pending: [UUID: PendingReconnection] = [:]

    // MARK: - Query

    func isReconnecting(_ panelId: UUID) -> Bool {
        pending[panelId] != nil
    }

    func retryCount(for panelId: UUID) -> Int {
        pending[panelId]?.retryCount ?? 0
    }

    func sshCommand(for panelId: UUID) -> String? {
        pending[panelId]?.sshCommand
    }

    func destination(for panelId: UUID) -> String? {
        pending[panelId]?.destination
    }

    /// Returns a title suffix like "Reconnecting (2/5)…" for display in the tab title.
    func titleSuffix(for panelId: UUID) -> String? {
        guard let state = pending[panelId] else { return nil }
        return String(
            localized: "ssh.reconnecting.title",
            defaultValue: "Reconnecting (\(state.retryCount)/\(Self.maxRetries))…"
        )
    }

    // MARK: - Lifecycle

    /// Schedule a reconnection attempt. Returns false if max retries exceeded.
    @discardableResult
    func schedule(
        oldPanelId: UUID,
        sshCommand: String,
        destination: String,
        retryCount: Int = 0,
        onReconnect: @escaping () -> Void
    ) -> Bool {
        let attempt = retryCount + 1
        guard attempt <= Self.maxRetries else {
            pending.removeValue(forKey: oldPanelId)
            return false
        }

        // Cancel any existing work item for this panel
        pending[oldPanelId]?.workItem?.cancel()

        let delay = Self.delay(for: attempt)

        var state = PendingReconnection(
            sshCommand: sshCommand,
            destination: destination,
            oldPanelId: oldPanelId,
            retryCount: attempt,
            startedAt: Date()
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard self?.pending[oldPanelId] != nil else { return }
            onReconnect()
        }
        state.workItem = workItem
        pending[oldPanelId] = state

        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return true
    }

    /// Cancel a pending reconnection.
    func cancel(panelId: UUID) {
        pending[panelId]?.workItem?.cancel()
        pending.removeValue(forKey: panelId)
    }

    /// Transfer reconnection state from an old panel to a new one.
    /// Called when the old panel is replaced by the reconnected terminal.
    func transfer(from oldPanelId: UUID, to newPanelId: UUID) -> Int {
        guard let state = pending.removeValue(forKey: oldPanelId) else { return 0 }
        state.workItem?.cancel()
        return state.retryCount
    }

    /// Mark reconnection as succeeded (new terminal stayed alive long enough).
    func clearSuccess(panelId: UUID) {
        pending.removeValue(forKey: panelId)
    }

    // MARK: - Internal

    private static func delay(for attempt: Int) -> TimeInterval {
        min(baseDelay * pow(2.0, Double(attempt - 1)), maxDelay)
    }
}
