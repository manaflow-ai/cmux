import Observation

/// Observable state for a temporary Cloud terminal creation panel.
@MainActor
@Observable
final class CloudTerminalPendingState {
    enum Phase: Equatable {
        case starting
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    private(set) var canRetry = false

    /// Resets the panel to its in-progress state for a retry.
    func resetForRetry() {
        phase = .starting
        canRetry = false
    }

    /// Shows a safe, localized failure message without exposing provider details.
    func showFailure(canRetry: Bool = true) {
        self.canRetry = canRetry
        phase = .failed(String(localized: "cloudTerminal.creation.failed.detail", defaultValue: "Could not confirm that the terminal is ready. Check the machine before trying again."))
    }
}
