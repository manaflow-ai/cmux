import Foundation

/// The identity and cancellable work of one host connection attempt.
struct MobileSSHConnectionAttempt<Connection: Sendable> {
    let id: UUID
    let task: Task<Connection, any Error>
}
