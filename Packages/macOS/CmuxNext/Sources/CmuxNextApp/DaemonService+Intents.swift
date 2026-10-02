import CmuxNextDaemon
import Foundation

// Commands that change what the store shows: typed intents (the store's
// intent log), the legacy optimistic patches still migrating to it
// (ownership.md step 4), and the read-your-writes wait after a command.
extension DaemonService {
    /// Runs an intent with an optimistic store patch settled by the daemon's
    /// transaction echo (or reverted on failure).
    func perform(_ label: String, patch: OptimisticPatch, expectEcho: Bool = false,
                 _ body: @escaping @Sendable (DaemonConnection, ClientTransactionID) async throws -> Void) async -> Bool {
        let ticket = openTicket()
        guard let connection else {
            await closeTicket(ticket, label: label, error: DaemonError.notConnected)
            return false
        }
        do {
            try await store.perform(patch, expectEcho: expectEcho) { transaction in
                try await body(connection, transaction)
            }
            await closeTicket(ticket, label: label, error: nil)
            return true
        } catch {
            logger.error("\(label, privacy: .public) rejected: \(String(describing: error), privacy: .public)")
            await closeTicket(ticket, label: label, error: error)
            return false
        }
    }

    /// Like `perform`, with a caller-chosen transaction (a drag commit keeps
    /// one id from drop to settle). Returns the body's value, or nil when the
    /// command threw (the patch is then reverted).
    func commit<T: Sendable>(_ label: String, patch: OptimisticPatch, transaction: ClientTransactionID, expectEcho: Bool,
                             _ body: @Sendable (DaemonConnection) async throws -> T) async -> T? {
        let ticket = openTicket()
        guard let connection else {
            logger.error("\(label, privacy: .public): not connected")
            await closeTicket(ticket, label: label, error: DaemonError.notConnected)
            return nil
        }
        store.applyOptimistic(patch, transaction: transaction)
        do {
            let value = try await body(connection)
            if !expectEcho { store.settleOptimistic(transaction) }
            await closeTicket(ticket, label: label, error: nil)
            return value
        } catch {
            store.rejectOptimistic(transaction)
            logger.error("\(label, privacy: .public) rejected: \(String(describing: error), privacy: .public)")
            await closeTicket(ticket, label: label, error: error)
            return nil
        }
    }

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
            // Every event the daemon emitted before the reply; nil when the
            // connection is gone, and then no event will come for it.
            store.noteSettled(transaction, at: await connection.eventSequence() ?? 0)
            await closeTicket(ticket, label: label, error: nil)
            return value
        } catch {
            store.rejectIntent(transaction)
            logger.error("\(label, privacy: .public) rejected: \(String(describing: error), privacy: .public)")
            await closeTicket(ticket, label: label, error: error)
            return nil
        }
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
            await closeTicket(ticket, label: label, error: nil)
            return value
        } catch {
            logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            await closeTicket(ticket, label: label, error: error)
            return nil
        }
    }

    /// Runs `body` once the store holds the result of the command that
    /// carried `transaction` (its echo, or every event the daemon emitted
    /// before the reply, which bounds a command that changed nothing). Call
    /// after the command's reply.
    func whenApplied(_ transaction: ClientTransactionID, _ body: @escaping @MainActor () -> Void) {
        guard let connection else { return body() }
        let store = store
        // task-owner: one actor hop to read the connection's routed event count; finishes at once, nothing to cancel
        Task { @MainActor in
            let barrier = await connection.eventSequence()
            guard let barrier else { return body() }
            store.whenApplied(transaction, reaching: barrier, body)
        }
    }
}
