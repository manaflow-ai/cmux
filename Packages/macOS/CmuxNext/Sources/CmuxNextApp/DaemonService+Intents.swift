import CmuxNextDaemon
import Foundation

// Commands that change what the store shows: typed intents (the store's
// intent log, the only optimistic mechanism; ownership.md step 4), plain
// requests that change nothing locally before the daemon reports them, and
// the read-your-writes wait after a command.
extension DaemonService {
    /// Sends a typed intent (OWNERSHIP-PRINCIPLES.md, "Clients are
    /// projections"): the store shows it at once on top of the confirmed
    /// mirror, and it leaves the log on its transaction's echo, once the
    /// store applied every event up to the sequence read after the reply,
    /// or when `body` throws. Returns the body's value, or nil on failure.
    func intend<T: Sendable>(_ label: String, _ intent: Intent, transaction: ClientTransactionID,
                             _ body: @Sendable (DaemonConnection) async throws -> T) async -> T? {
        let ticket = openTicket()
        guard let connection else {
            logger.error("\(label, privacy: .public): not connected")
            await closeTicket(ticket, label: label, error: DaemonError.notConnected)
            return nil
        }
        store.intend(intent, transaction: transaction)
        do {
            let value = try await body(connection)
            // Every event the daemon emitted before the reply. Nil when the
            // connection is gone: no event will come on it, and the next
            // connection's first snapshot holds the result.
            if let sequence = await connection.eventSequence() {
                store.noteSettled(transaction, at: sequence)
            } else {
                store.noteSettledAtNextSnapshot(transaction)
            }
            await closeTicket(ticket, label: label, error: nil, replying: connection)
            return value
        } catch {
            store.rejectIntent(transaction)
            logger.error("\(label, privacy: .public) rejected: \(String(describing: error), privacy: .public)")
            await closeTicket(ticket, label: label, error: error)
            return nil
        }
    }

    /// `intend` with a fresh transaction, for commands that do not carry
    /// one. Returns whether the command succeeded.
    func intend(_ label: String, _ intent: Intent, _ body: @Sendable (DaemonConnection) async throws -> Void) async -> Bool {
        await intend(label, intent, transaction: .generate(), body) != nil
    }

    /// `request` for commands that carry a transaction (their events echo
    /// it): `transaction` defaults to a fresh one. Returns the body's
    /// value, or nil when it failed (logged).
    func request<T: Sendable>(_ label: String, transaction: ClientTransactionID = .generate(),
                              _ body: @Sendable (DaemonConnection, ClientTransactionID) async throws -> T) async -> T? {
        await request(label) { connection in try await body(connection, transaction) }
    }

    /// A tab group command with a fresh transaction (its events echo it):
    /// an intent when it has one, else a plain request.
    func runGroupCommand(_ label: String, intent: Intent?,
                         _ body: @escaping @Sendable (DaemonConnection, ClientTransactionID) async throws -> Void) async -> Bool {
        let transaction = ClientTransactionID.generate()
        guard let intent else { return await request(label, transaction: transaction, body) != nil }
        return await intend(label, intent, transaction: transaction) { connection in try await body(connection, transaction) } != nil
    }

    /// Runs a command that changes nothing locally before the daemon
    /// reports it (no intent to show). Returns the body's value, or nil
    /// when it failed (logged).
    func request<T: Sendable>(_ label: String, _ body: @Sendable (DaemonConnection) async throws -> T) async -> T? {
        let ticket = openTicket()
        guard let connection else {
            logger.error("\(label, privacy: .public): not connected")
            await closeTicket(ticket, label: label, error: DaemonError.notConnected)
            return nil
        }
        do {
            let value = try await body(connection)
            await closeTicket(ticket, label: label, error: nil, replying: connection)
            return value
        } catch {
            logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            await closeTicket(ticket, label: label, error: error)
            return nil
        }
    }
}
