import Foundation

struct WorkspaceCapturedLink: Identifiable, Equatable, Hashable, Sendable {
    var id: UUID
    var url: String
    var hostKey: String?
    var firstSeen: Date
    var lastSeen: Date
    var count: Int
    var sourcePanelId: UUID?
    var sourceSurfaceTitle: String?
    var origin: WorkspaceCapturedLinkOrigin
    var fetchedTitle: String?
    var titleFetchState: WorkspaceLinkTitleFetchState = .idle
    var titleFetchGeneration: UInt64 = 0
    var activeTitleFetchID: UUID?
    var titleFetchRetryAfter: Date? = nil
}
