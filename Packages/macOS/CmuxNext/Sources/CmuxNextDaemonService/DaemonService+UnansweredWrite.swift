public import CmuxNextActions
public import CmuxNextDaemon
import CmuxNextWakeups
import Foundation

extension DaemonService {
    /// ``perform(_:_:)`` for a write the sidebar already shows and that sets absolute values: a missed deadline or a
    /// lost connection (``PersonalWriteLedger/isUnanswered(_:)``) is not a refusal, so `body` goes again, spaced by
    /// ``Backoff`` (0.25 s doubling to 5 s), until the daemon answers. Returns its value, or nil when, before a retry,
    /// `superseded` says a newer write to the same thing was made (last write wins; nothing to undo or report) or the
    /// connection was shut down (quit, teardown). Throws only a definite refusal, the one error a caller rolls back for.
    ///
    /// The ticket closes at the first unanswered try with that error, as ``perform(_:_:)`` would, and `unanswered`
    /// runs then: an action awaited from the control socket reads that the write may still apply, and no script
    /// waits on retries.
    public func performUntilAnswered<T: Sendable>(_ label: String, superseded: @escaping @MainActor () -> Bool,
                                                  unanswered: (@MainActor () async -> Void)? = nil,
                                                  _ body: @Sendable (isolated DaemonConnection) async throws -> T) async throws -> T? {
        var ticket = openTicket(label), backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(5), jitter: 0.1)
        let shutdownsAtStart = shutdowns
        // Ends on the answer, a refusal, a newer write, a shutdown or cancellation; each pass waits its backoff first.
        for attempt in 0... {
            // Only a write being sent again yields: a first send keeps its place in line (a queued placement whose
            // successor also moves its workspaces still sends the others).
            if attempt > 0, superseded() || shutdowns != shutdownsAtStart || Task.isCancelled {
                await closeTicket(ticket, label: label, error: nil)
                logger.info("\(label, privacy: .public): superseded, shut down or cancelled; not sent again")
                return nil
            }
            do {
                guard let connection else { throw DaemonError.notConnected }
                let value = try await body(connection)
                await closeTicket(ticket, label: label, error: nil, replying: connection)
                return value
            } catch where PersonalWriteLedger.isUnanswered(error) {
                if attempt == 0 { await unanswered?() }
                await closeTicket(ticket, label: label, error: error)
                ticket = nil
                logger.info("\(label, privacy: .public) unanswered (\(String(describing: error), privacy: .public)); sending it again (try \(attempt + 2))")
                // concurrency-allow: an async Backoff wait suspends this task; it never blocks the main thread
                try? await backoff.wait(owner: "personal write retry")
            } catch {
                await closeTicket(ticket, label: label, error: error)
                throw error
            }
        }
        return nil
    }
}

extension DaemonService {
    /// ``perform(_:_:)`` with no `claim`; else ``performUntilAnswered(_:superseded:unanswered:_:)`` until a newer write
    /// supersedes the claim (nil then).
    public func perform<T: Sendable>(_ label: String, until claim: PersonalWriteLedger.Claim?, unanswered: (@MainActor () async -> Void)?,
                                     _ body: @Sendable (isolated DaemonConnection) async throws -> T) async throws -> T? {
        guard let claim else { return try await perform(label, body) }
        let writes = store.personal.writes
        return try await performUntilAnswered(label, superseded: { writes.isSuperseded(claim) }, unanswered: unanswered, body)
    }

    /// ``performUntilAnswered(_:superseded:unanswered:_:)`` for a sidebar edit, on its own task: `failed` gets a
    /// refusal's why; `applied` runs once the store holds the write, or at once when a newer write superseded it.
    public func sendUntilAnswered(_ label: String, until claim: PersonalWriteLedger.Claim,
                                  _ outcome: (failed: @MainActor (ActionWorkFailure) -> Void, applied: (@MainActor () -> Void)?),
                                  _ body: @escaping DaemonCommandBody) {
        let writes = store.personal.writes, (failed, applied) = outcome
        // task-owner: one personal write, sent again while unanswered; ends on its answer, a refusal or a newer write
        Task {
            do {
                guard try await performUntilAnswered(label, superseded: { writes.isSuperseded(claim) }, body) != nil else {
                    applied?()
                    return
                }
            } catch {
                return failed(workFailure(label, error))
            }
            whenApplied(.generate()) { applied?() }
        }
    }
}
