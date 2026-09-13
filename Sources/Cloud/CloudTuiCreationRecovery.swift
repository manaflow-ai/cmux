import Foundation

enum CloudTuiCreationRecovery: String, Equatable, Sendable {
    case retrySameIdempotencyKey = "retry_same_idempotency_key"
    case retryNewIdempotencyKey = "retry_new_idempotency_key"
    case wait
    case none
    case doNotRetry = "do_not_retry"
}
