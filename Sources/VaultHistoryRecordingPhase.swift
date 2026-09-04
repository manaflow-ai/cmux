import Foundation

/// App lifecycle phase that decides whether semantic History events are accepted.
enum VaultHistoryRecordingPhase: Equatable, Sendable {
    /// App composition exists, but startup restore intent is not resolved yet.
    case launching
    /// User and external actions should be recorded.
    case active
    /// Programmatic session restoration should not emit lifecycle events.
    case restoring
    /// App teardown should not turn bulk closure into user history.
    case terminating
}
