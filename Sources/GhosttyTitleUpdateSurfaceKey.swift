import Foundation

/// Identifies title-publication state for one concrete Ghostty surface lifetime.
struct GhosttyTitleUpdateSurfaceKey: Hashable {
    let tabId: UUID
    let surfaceId: UUID
    let sourceSurfaceIdentifier: ObjectIdentifier
}
