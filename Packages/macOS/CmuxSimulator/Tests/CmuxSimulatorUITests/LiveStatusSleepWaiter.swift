import Foundation

struct LiveStatusSleepWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, any Error>
}
