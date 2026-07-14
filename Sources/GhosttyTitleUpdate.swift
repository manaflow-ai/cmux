import Foundation

/// Sendable title payload captured at the Ghostty callback boundary.
struct GhosttyTitleUpdate: Equatable, Sendable {
    let tabId: UUID
    let surfaceId: UUID
    let title: String
    let sourceSurfaceIdentifier: ObjectIdentifier
    let sequence: UInt64
}
