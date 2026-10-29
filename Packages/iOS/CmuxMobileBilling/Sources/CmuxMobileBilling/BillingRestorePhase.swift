import Foundation

/// The state of Restore Purchases.
public enum BillingRestorePhase: Sendable, Equatable {
    /// No restore to show.
    case idle
    /// `AppStore.sync()` or the re-post is running.
    case restoring
    /// Restore finished; `acceptedCount` subscriptions were re-posted and
    /// accepted by the server.
    case completed(acceptedCount: Int)
    /// Restore failed.
    case failed(BillingFailure)
}
