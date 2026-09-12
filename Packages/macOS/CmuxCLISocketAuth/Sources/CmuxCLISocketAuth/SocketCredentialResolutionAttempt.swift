public import Foundation

/// Owns the lifetime of one socket client's deferred credential lookup.
///
/// The shared resolver caches source results; this value gates the client's
/// attempts without storing another copy of the password. Recreate it when
/// configuring a client's credentials. Its clock uses the same absolute time
/// as the operation deadline.
public struct SocketCredentialResolutionAttempt: Sendable {
    /// A lookup failure that must not be mistaken for missing credentials.
    public enum Failure: Error {
        /// The operation's deadline elapsed before the result was available.
        case deadlineExceeded
    }

    private let now: @Sendable () -> Date

    /// Whether another deferred lookup is suppressed for this client.
    public private(set) var isCompleted = false

    /// Creates an unattempted client-level resolution.
    ///
    /// - Parameter now: The operation clock, defaulting to the current date.
    public init(now: @escaping @Sendable () -> Date = { Date.now }) {
        self.now = now
    }

    /// Resolves a credential without admitting work after its deadline.
    ///
    /// The synchronous provider cannot be forcibly cancelled. An over-deadline
    /// result is not available for authentication in the expired operation,
    /// but leaves the attempt eligible for a later operation's fresh deadline.
    ///
    /// - Parameters:
    ///   - provider: The source resolver shared by clients on this socket route.
    ///   - deadline: The operation's absolute deadline, or `nil` if unbounded.
    /// - Returns: The provider's result when it completes within the deadline.
    /// - Throws: ``Failure/deadlineExceeded`` when the operation expires, so
    ///   callers can retry instead of treating the result as missing credentials.
    public mutating func resolve(
        provider: (Date?) -> String?,
        deadline: Date?
    ) throws(Failure) -> String? {
        guard !isCompleted else { return nil }
        if let deadline, now() >= deadline { throw .deadlineExceeded }
        let password = provider(deadline)
        if let deadline, now() >= deadline { throw .deadlineExceeded }
        isCompleted = true
        return password
    }
}
