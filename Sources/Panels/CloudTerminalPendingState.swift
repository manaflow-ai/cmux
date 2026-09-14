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

    /// Resets the panel to its in-progress state for a retry.
    func resetForRetry() {
        phase = .starting
    }

    /// Shows a safe, localized failure message without exposing provider details.
    func showFailure() {
        phase = .failed(String(localized: "cloudTerminal.creation.failed.detail", defaultValue: "The Cloud service did not accept the terminal request."))
    }
}
