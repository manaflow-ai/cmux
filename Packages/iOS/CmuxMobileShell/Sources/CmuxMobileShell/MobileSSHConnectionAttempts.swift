import Foundation

/// Coalesces SSH handshakes and owns their publication and cancellation.
/// The connection value is generic so lifecycle tests can hold a handshake
/// without starting a server or reading the user's keychain.
@MainActor
final class MobileSSHConnectionAttempts<Connection: Sendable> {
    private struct Attempt {
        let id: UUID
        let task: Task<Connection, any Error>
    }

    private var attempts: [UUID: Attempt] = [:]

    func isConnecting(hostID: UUID) -> Bool {
        attempts[hostID] != nil
    }

    func cancel(hostID: UUID) {
        attempts.removeValue(forKey: hostID)?.task.cancel()
    }

    func connection(
        hostID: UUID,
        connect: @escaping @MainActor () async throws -> Connection,
        discard: @escaping @MainActor (Connection) async -> Void,
        connected: @escaping @MainActor (Connection) -> Void,
        failed: @escaping @MainActor (any Error) -> Void
    ) async throws -> Connection {
        let attempt: Attempt
        if let existing = attempts[hostID] {
            attempt = existing
        } else {
            let task = Task {
                let connection: Connection
                do {
                    try Task.checkCancellation()
                    connection = try await connect()
                } catch {
                    guard !Task.isCancelled else { throw MobileSSHConnectionAttemptSuperseded() }
                    failed(error)
                    throw error
                }
                guard !Task.isCancelled else {
                    await discard(connection)
                    throw MobileSSHConnectionAttemptSuperseded()
                }
                // Publication belongs to the shared task, so joining callers
                // cannot observe an unchecked or unpublished connection.
                connected(connection)
                return connection
            }
            attempt = Attempt(id: UUID(), task: task)
            attempts[hostID] = attempt
        }
        defer {
            if attempts[hostID]?.id == attempt.id { attempts[hostID] = nil }
        }
        do {
            let connection = try await attempt.task.value
            guard !attempt.task.isCancelled else { throw MobileSSHConnectionAttemptSuperseded() }
            return connection
        } catch {
            // Cancellation may occur after the task finishes but before this
            // waiter resumes; stale failures must not overwrite a new status.
            guard !attempt.task.isCancelled else { throw MobileSSHConnectionAttemptSuperseded() }
            throw error
        }
    }
}
