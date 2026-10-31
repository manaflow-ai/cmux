/// Searches connected daemons in order for a closed link target.
///
/// A daemon that does not hold the target lets the search continue. Any other
/// failure stops it, since the request may already have changed that daemon.
/// `Daemon` is an equatable identifier supplied by the caller.
@MainActor
public struct ClosedLinkSearch<Daemon: Equatable> {
    /// One daemon's answer to a reopen request.
    public enum Answer: Equatable {
        /// It held the target and reopened it.
        case reopened
        /// No closed group holds the target.
        case notInHistory
    }

    /// The result of searching the daemons.
    public enum Outcome: Equatable {
        /// The named daemon reopened the target.
        case reopened(on: Daemon)
        /// No daemon holds the target.
        case gone
        /// The named daemon failed, so the search stopped.
        case failed(on: Daemon)
    }

    private let daemons: [Daemon]

    /// Creates a search over the connected daemons, local first.
    /// - Parameter daemons: Identifiers in the order they should be asked.
    public init(daemons: [Daemon]) {
        self.daemons = daemons
    }

    /// Asks each daemon until one reopens the target.
    /// - Parameter ask: Reopens the target, or throws for a failure other than
    ///   not-in-history.
    /// - Returns: The daemon that reopened it, no target, or the failing daemon.
    public func reopen(_ ask: (Daemon) async throws -> Answer) async -> Outcome {
        for daemon in daemons {
            do {
                if try await ask(daemon) == .reopened { return .reopened(on: daemon) }
            } catch {
                return .failed(on: daemon)
            }
        }
        return .gone
    }
}
