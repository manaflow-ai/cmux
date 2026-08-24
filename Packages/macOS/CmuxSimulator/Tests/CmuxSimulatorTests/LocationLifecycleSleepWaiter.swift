import Foundation

struct LocationLifecycleSleepWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, any Error>
}
