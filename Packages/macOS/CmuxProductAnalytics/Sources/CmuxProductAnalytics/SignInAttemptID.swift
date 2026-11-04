public import Foundation

/// Joins one sign-in attempt's started, callback, window-closed and result
/// events. A fresh random UUID per started sign-in, held only in memory; it is
/// derived from nothing, so it identifies no person, account or device.
public struct SignInAttemptID: Sendable, Hashable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    /// The lowercase UUID form sent as `attempt_id`.
    public var token: String { rawValue.uuidString.lowercased() }
}
