public import CmuxNextDaemon
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
    public func intend<T: Sendable>(_ label: String, _ intent: Intent, transaction: ClientTransactionID,
                             _ body: @Sendable (isolated DaemonConnection) async throws -> T) async -> T? {
        await withoutActuallyEscaping(body) { await intendNow(label, intent, transaction: transaction, $0)() }
    }

    /// ``intend(_:_:transaction:_:)`` in two steps (Cmd-D): the intent shows now, before any await; the returned work sends `body`.
    public func intendNow<T: Sendable>(_ label: String, _ intent: Intent, transaction: ClientTransactionID,
                                       _ body: @escaping @Sendable (isolated DaemonConnection) async throws -> T) -> @MainActor () async -> T? {
        let send = intendNowReporting(label, intent, transaction: transaction, body)
        return { try? await send().get() }
    }

    /// ``intendNow(_:_:transaction:_:)`` whose work returns the failure too (``intentEffect(_:_:_:)``).
    func intendNowReporting<T: Sendable>(_ label: String, _ intent: Intent, transaction: ClientTransactionID,
                                         _ body: @escaping @Sendable (isolated DaemonConnection) async throws -> T)
        -> @MainActor () async -> Result<T, any Error> {
        let ticket = openTicket(label)
        guard let connection else {
            return { [self] in
                logger.error("\(label, privacy: .public): not connected")
                await closeTicket(ticket, label: label, error: DaemonError.notConnected)
                return .failure(DaemonError.notConnected)
            }
        }
        #if DEBUG || CMUX_BENCH_HOOKS
        let held = creationHold.creationStarted(label)
        creationHold.intend(held) { [store] in store.intend(intent, transaction: transaction) } // a held stand-in shows at its release
        #else
        store.intend(intent, transaction: transaction)
        #endif
        return { [self] in do {
            let value = try await body(connection)
            #if DEBUG || CMUX_BENCH_HOOKS
            await creationHold.replied(held) // a test's held creation reply (debug.creation.hold)
            #endif
            // Every event the daemon emitted before the reply. Nil when the
            // connection is gone: no event will come on it, and the next
            // connection's first snapshot holds the result.
            if let sequence = await connection.eventSequence() {
                store.noteSettled(transaction, at: sequence)
            } else {
                store.noteSettledAtNextSnapshot(transaction)
            }
            await closeTicket(ticket, label: label, error: nil, replying: connection)
            return .success(value)
        } catch {
            Self.checkStandInRollback(intent, error: error, label: label)
            store.rejectIntent(transaction)
            logger.error("\(label, privacy: .public) rejected: \(String(describing: error), privacy: .public)")
            await closeTicket(ticket, label: label, error: error)
            return .failure(error)
        } }
    }

    /// `intend` with a fresh transaction, for commands that do not carry
    /// one. Returns whether the command succeeded.
    public func intend(_ label: String, _ intent: Intent, _ body: DaemonCommandBody) async -> Bool {
        await intend(label, intent, transaction: .generate(), body) != nil
    }

    /// `request` for commands that carry a transaction (their events echo
    /// it): `transaction` defaults to a fresh one. Returns the body's
    /// value, or nil when it failed (logged).
    public func request<T: Sendable>(_ label: String, transaction: ClientTransactionID = .generate(),
                              _ body: @Sendable (DaemonConnection, ClientTransactionID) async throws -> T) async -> T? {
        await request(label) { connection in try await body(connection, transaction) }
    }

    /// A tab group command with a fresh transaction (its events echo it):
    /// an intent when it has one, else a plain request.
    public func runGroupCommand(_ label: String, intent: Intent?,
                         _ body: @escaping @Sendable (DaemonConnection, ClientTransactionID) async throws -> Void) async -> Bool {
        let transaction = ClientTransactionID.generate()
        guard let intent else { return await request(label, transaction: transaction, body) != nil }
        return await intend(label, intent, transaction: transaction) { connection in try await body(connection, transaction) } != nil
    }

    /// Runs a command that changes nothing locally before the daemon
    /// reports it (no intent to show). Returns the body's value, or nil
    /// when it failed (logged).
    public func request<T: Sendable>(_ label: String, _ body: @Sendable (isolated DaemonConnection) async throws -> T) async -> T? {
        let ticket = openTicket(label)
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

    /// `request` for callers that handle the failure themselves: it still
    /// goes to the action scope (ticket, barrier, failure), and is rethrown.
    public func perform<T: Sendable>(_ label: String, _ body: @Sendable (isolated DaemonConnection) async throws -> T) async throws -> T {
        let ticket = openTicket(label)
        guard let connection else {
            await closeTicket(ticket, label: label, error: DaemonError.notConnected)
            throw DaemonError.notConnected
        }
        do {
            let value = try await body(connection)
            await closeTicket(ticket, label: label, error: nil, replying: connection)
            return value
        } catch {
            await closeTicket(ticket, label: label, error: error)
            throw error
        }
    }
}
