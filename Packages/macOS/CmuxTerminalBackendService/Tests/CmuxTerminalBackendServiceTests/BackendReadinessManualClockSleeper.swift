import Foundation

struct BackendReadinessManualClockSleeper {
    let deadline: BackendReadinessManualClockInstant
    let continuation: CheckedContinuation<Void, any Error>
}
