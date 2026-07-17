internal import Foundation

/// Main-actor state for one endpoint's active attempt, cooldown, and FIFO waiters.
struct NativeSSHConnectionAttemptState {
    var activeToken: UUID?
    var waiterOrder: [UUID] = []
    var waiters: [UUID: CheckedContinuation<NativeSSHConnectionPermit, any Error>] = [:]
    var cooldownToken: UUID?
    var cooldownTask: Task<Void, Never>?
}
