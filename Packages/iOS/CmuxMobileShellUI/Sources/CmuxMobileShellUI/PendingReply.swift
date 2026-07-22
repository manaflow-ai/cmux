import Foundation

/// A single inline notification reply parked until its target Mac can accept input.
struct PendingReply: Equatable, Sendable {
    let text: String
    let workspaceId: String?
    let surfaceId: String?
    let macDeviceId: String?
    let retargetsToLiveSurfaceOwner: Bool
    let createdAt: Date
}
