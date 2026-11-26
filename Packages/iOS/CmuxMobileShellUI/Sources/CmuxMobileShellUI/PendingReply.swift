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
    let macInstallationID: String?
    let macBuildID: String?
    let retargetsToLiveSurfaceOwner: Bool
    let createdAt: Date

    init(
        replyId: String,
        text: String,
        workspaceId: String?,
        surfaceId: String?,
        macDeviceId: String?,
        macInstanceTag: String?,
        macInstallationID: String? = nil,
        macBuildID: String? = nil,
        retargetsToLiveSurfaceOwner: Bool,
        createdAt: Date
    ) {
        self.replyId = replyId
        self.text = text
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.macDeviceId = macDeviceId
        self.macInstanceTag = macInstanceTag
        self.macInstallationID = macInstallationID
        self.macBuildID = macBuildID
        self.retargetsToLiveSurfaceOwner = retargetsToLiveSurfaceOwner
        self.createdAt = createdAt
    }
}
