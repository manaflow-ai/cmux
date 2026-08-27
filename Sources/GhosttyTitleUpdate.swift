import Foundation

/// Sendable title payload captured at the Ghostty callback boundary.
struct GhosttyTitleUpdate: Equatable, Sendable {
    let tabId: UUID
    let surfaceId: UUID
    let title: String
    let sourceSurfaceIdentifier: ObjectIdentifier
    let terminalLifecycleID: UUID
    let attachmentGeneration: UInt64

    init(
        tabId: UUID,
        surfaceId: UUID,
        title: String,
        sourceSurfaceIdentifier: ObjectIdentifier,
        terminalLifecycleID: UUID,
        attachmentGeneration: UInt64 = 0
    ) {
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.title = title
        self.sourceSurfaceIdentifier = sourceSurfaceIdentifier
        self.terminalLifecycleID = terminalLifecycleID
        self.attachmentGeneration = attachmentGeneration
    }
}
