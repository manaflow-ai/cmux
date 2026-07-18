import Foundation

/// Errors that reject durable acknowledged Feed ingestion before an
/// acknowledgement is returned to the sender.
public enum WorkstreamPersistenceError: Error, Sendable, Equatable {
    /// The store was asked to acknowledge an event without durable persistence.
    case persistenceUnavailable

    /// The acknowledged event did not contain a non-empty request identifier.
    case missingRequestIdentity

    /// The live receipt count reached its configured bound.
    ///
    /// Existing identities remain retryable at this bound. New identities must
    /// wait for a receipt to expire rather than evicting a live receipt.
    case receiptCountLimitReached(maximumCount: Int)

    /// The receipt database, write-ahead log, or shared-memory index reached its bound.
    ///
    /// Existing identities remain retryable at this bound. New identities receive
    /// explicit backpressure instead of growing storage without limit.
    case receiptByteLimitReached(maximumBytes: Int64)
}
