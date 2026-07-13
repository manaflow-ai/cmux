public import Foundation

/// Stable identity for one logical task submission.
///
/// A retry reuses the same identity. Any edit that changes the requested task
/// rotates it so the Mac cannot mistake a new request for the previous one.
public struct MobileTaskSubmissionIdentity: Equatable, Sendable {
    /// Identity sent with `workspace.create`.
    public private(set) var id: UUID

    /// Creates an identity, restoring `id` for a retry when one exists.
    public init(id: UUID = UUID()) {
        self.id = id
    }

    /// Starts a distinct logical submission after composer input changes.
    public mutating func rotate() {
        id = UUID()
    }
}
