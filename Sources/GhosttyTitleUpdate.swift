import Foundation

/// Sendable title payload captured at the Ghostty callback boundary.
struct GhosttyTitleUpdate: Equatable, Sendable {
    let tabId: UUID
    let surfaceId: UUID
    let title: String
    let sourceSurfaceIdentifier: ObjectIdentifier
    let attachmentGeneration: UInt64

    init(
        tabId: UUID,
        surfaceId: UUID,
        title: String,
        sourceSurfaceIdentifier: ObjectIdentifier,
        attachmentGeneration: UInt64 = 0
    ) {
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.title = title
        self.sourceSurfaceIdentifier = sourceSurfaceIdentifier
        self.attachmentGeneration = attachmentGeneration
    }
}
