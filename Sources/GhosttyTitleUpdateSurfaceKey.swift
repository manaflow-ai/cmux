import Foundation

/// Identifies title-publication state for one concrete Ghostty surface lifetime.
nonisolated struct GhosttyTitleUpdateSurfaceKey: Hashable, Sendable {
    let tabId: UUID
    let surfaceId: UUID
    let sourceSurfaceIdentifier: ObjectIdentifier
}
