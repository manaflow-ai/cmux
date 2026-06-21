public import Foundation

/// A single file the workspace drop opens as a file-preview surface, mirroring
/// the one field the legacy file-drop paths read off the app-target
/// `FilePreviewDragEntry` (the file-preview drag) and the app-target
/// `FilePreviewDragEntry` the external-file drop synthesizes from a dropped
/// `URL`.
///
/// Both the in-app file-preview drag and the Finder external-file drop reduce to
/// the same thing once the host has resolved them: a file path to open. The host
/// projects each into this Sendable struct so ``WorkspaceDropCoordinator`` can
/// route the open/split without importing the app-target entry type.
public struct WorkspaceFileDropPayload: Sendable, Equatable {
    /// The file path to open as a preview surface (legacy
    /// `FilePreviewDragEntry.filePath`, or the dropped file `URL.path`).
    public let filePath: String

    /// Creates a file drop payload.
    /// - Parameter filePath: the file path to open.
    public init(filePath: String) {
        self.filePath = filePath
    }
}
