import Foundation

/// Identity carried by one Lock Mac request so a late result cannot overwrite a
/// later Sleepy Mode session or request.
struct SleepyLockRequest: Sendable {
    let sessionID: UUID
    let requestID: UInt64
}
