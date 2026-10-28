import Foundation

/// Coalesces SSH handshakes and owns their publication and cancellation.
/// The connection value is generic so lifecycle tests can hold a handshake
/// without starting a server or reading the user's keychain.
@MainActor
final class MobileSSHConnectionAttempts<Connection: Sendable> {
    private var tasks: [UUID: Task<Connection, any Error>] = [:]

    func isConnecting(hostID: UUID) -> Bool {
        tasks[hostID] != nil
    }

    func cancel(hostID: UUID) {
        tasks.removeValue(forKey: hostID)?.cancel()
    }

    func connection(
        hostID: UUID,
        connect: @escaping @MainActor () async throws -> Connection,
        discard: @escaping @MainActor (Connection) async -> Void,
        connected: @escaping @MainActor (Connection) -> Void,
        failed: @escaping @MainActor (any Error) -> Void
    ) async throws -> Connection {
        if let task = tasks[hostID] { return try await task.value }
        let task = Task { try await connect() }
        tasks[hostID] = task
        defer { tasks[hostID] = nil }
        let connection: Connection
        do {
            connection = try await task.value
        } catch {
            failed(error)
            throw error
        }
        connected(connection)
        return connection
    }
}
