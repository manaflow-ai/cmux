import Foundation

/// A redacted value snapshot of one browser grant.
///
/// The bearer token is intentionally not retained in this value and is
/// returned only by ``WebClientGrantStore/issue``.
nonisolated struct WebClientGrantSnapshot: Equatable, Sendable {
    let id: UUID
    let label: String
    let createdAt: Date
    let lastUsedAt: Date?
    let revokedAt: Date?

    var isActive: Bool { revokedAt == nil }
}
