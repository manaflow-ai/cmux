internal import CmuxTerminalBackend

/// Immutable daemon metadata for one tab in canonical tab order.
nonisolated struct BackendOnlyProjectionTabMetadata: Equatable, Sendable {
    let surfaceID: SurfaceID
    let numericSurfaceID: UInt64
    let kind: String
    let name: String?
    let browserEndpoint: CanonicalBrowserEndpoint?
    let externalTerminalProvenance: CanonicalExternalTerminalProvenance?
    let isSelected: Bool
}
