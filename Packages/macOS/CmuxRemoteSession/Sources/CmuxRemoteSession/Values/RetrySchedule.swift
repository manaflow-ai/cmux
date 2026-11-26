internal import Foundation

/// One step of a reconnect backoff schedule: the retry ordinal and its delay.
/// Lifted one-for-one from the legacy controller's nested type.
struct RetrySchedule {
    let retry: Int
    let delay: TimeInterval
}
