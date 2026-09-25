import Foundation

/// Identifies title-publication state for one concrete Ghostty surface lifetime.
/// The owning tab is routing metadata and is intentionally excluded because a
/// live surface can move between workspaces without changing its lifetime.
struct GhosttyTitleUpdateSurfaceKey: Hashable, Sendable {
    let surfaceId: UUID
    let sourceSurfaceIdentifier: ObjectIdentifier

    init(surfaceId: UUID, sourceSurfaceIdentifier: ObjectIdentifier) {
        self.surfaceId = surfaceId
        self.sourceSurfaceIdentifier = sourceSurfaceIdentifier
    }

    init(surfaceId: UUID, sourceSurface: AnyObject) {
        self.init(
            surfaceId: surfaceId,
            sourceSurfaceIdentifier: ObjectIdentifier(sourceSurface)
        )
    }
}
