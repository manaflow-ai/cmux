public import Foundation

/// One opened-surface row of the `file.open` payload (the legacy
/// `v2FileOpenSurfacePayload` dictionary, minus the coordinator-minted refs).
public struct ControlFileOpenSurface: Sendable, Equatable {
    /// The opened panel's identifier.
    public let surfaceID: UUID
    /// The panel's pane, if it resolved.
    public let paneID: UUID?
    /// The panel type's raw value.
    public let panelTypeRawValue: String
    /// The opened file path (file-preview and markdown panels only).
    public let path: String?
    /// The preview mode's socket name (file-preview panels only).
    public let previewMode: String?
    /// The display mode's raw value (markdown panels only).
    public let displayMode: String?

    /// Creates an opened-surface row.
    ///
    /// - Parameters:
    ///   - surfaceID: The opened panel's identifier.
    ///   - paneID: The panel's pane, if any.
    ///   - panelTypeRawValue: The panel type's raw value.
    ///   - path: The opened file path, if carried.
    ///   - previewMode: The preview mode's socket name, if carried.
    ///   - displayMode: The display mode's raw value, if carried.
    public init(
        surfaceID: UUID,
        paneID: UUID?,
        panelTypeRawValue: String,
        path: String?,
        previewMode: String?,
        displayMode: String?
    ) {
        self.surfaceID = surfaceID
        self.paneID = paneID
        self.panelTypeRawValue = panelTypeRawValue
        self.path = path
        self.previewMode = previewMode
        self.displayMode = displayMode
    }
}
