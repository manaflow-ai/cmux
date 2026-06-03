import Foundation

/// A generic mobile API response indicating whether an operation succeeded.
public struct MobileOKResponse: Decodable, Equatable, Sendable {
    /// Whether the operation succeeded.
    public let ok: Bool

    /// Creates an OK response.
    ///
    /// - Parameter ok: Whether the operation succeeded.
    public init(ok: Bool) {
        self.ok = ok
    }
}
