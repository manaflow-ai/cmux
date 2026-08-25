import Foundation

/// A single inline notification reply parked until its target Mac can accept input.
struct PendingReply: Equatable, Sendable {
    /// Stable idempotency key for the server relay: retries re-send this id,
    /// so the inbox can never park one reply twice.
    let replyId: String
    let text: String
    let workspaceId: String?
    let surfaceId: String?
    let macDeviceId: String?
    let macInstanceTag: String?
    let retargetsToLiveSurfaceOwner: Bool
    let createdAt: Date
}
