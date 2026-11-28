import Foundation

/// One error in the iPhone app's connection state, stamped the way a Kubernetes condition is: who set it (`setBy`)
/// and at which generation. Fresh data on the same stream clears any error stamped at an older generation, so a
/// stale error never outlives the data that disproves it (Leo, 2026-11-27: "Stale errors clear on fresh data." and
/// "An error set by a timeout clears when the next good data arrives, as in #62661.").
///
/// Each stream (the workspaces list, ...) holds one ``ConnectionErrorStamp``; ``LiveCoordinator`` is the only
/// writer. Every event takes the next generation:
/// - ``set(_:by:startedAt:)`` stamps an error. A fetch's failure passes the generation its read began at
///   (``begin()``); when good data arrived after that, the failure is older than the data and is dropped.
/// - ``fresh()`` records good data: it clears a `.timeout` or `.fetch` error (always older than this event). A
///   `.user` error (a refusal the person gave) stays until the person acts, since data does not answer it.
/// - ``clear()`` is a new attempt (a new link, a Retry): it starts clean.
struct ConnectionErrorStamp: Equatable {
    enum SetBy: String, Equatable, Sendable {
        /// A deadline passed with no data (e.g. ``LiveCoordinator/workspacesDeadline``).
        case timeout
        /// A read failed or returned something unusable.
        case fetch
        /// The person's own action (a refusal); data does not clear it.
        case user
    }

    struct Stamped: Equatable {
        let message: String
        let setBy: SetBy
        let generation: UInt64
    }

    private(set) var error: Stamped?
    /// The last generation handed out.
    private(set) var generation: UInt64 = 0
    /// The generation good data last arrived at (0: none yet).
    private(set) var freshAt: UInt64 = 0

    var message: String? { error?.message }

    /// A read begins: the generation its failure, if any, reports with `startedAt`.
    mutating func begin() -> UInt64 {
        generation += 1
        return generation
    }

    /// Stamps MESSAGE set by SETBY. A failure from a read that began (STARTEDAT) before good data arrived is
    /// stale: it is dropped and false returned.
    @discardableResult
    mutating func set(_ message: String, by setBy: SetBy, startedAt: UInt64? = nil) -> Bool {
        if let startedAt, startedAt < freshAt { return false }
        generation += 1
        error = Stamped(message: message, setBy: setBy, generation: generation)
        return true
    }

    /// Good data arrived: clears a timeout or fetch error stamped before it. True when it cleared one.
    @discardableResult
    mutating func fresh() -> Bool {
        generation += 1
        freshAt = generation
        guard let error, error.setBy != .user, error.generation < freshAt else { return false }
        self.error = nil
        return true
    }

    /// A new attempt starts clean.
    mutating func clear() {
        error = nil
    }
}
