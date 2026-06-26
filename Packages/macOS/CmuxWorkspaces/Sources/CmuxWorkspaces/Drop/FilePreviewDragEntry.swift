/// The payload a file-preview drag carries while it is in flight: the file to
/// open and the title shown on the synthesized drag tab.
///
/// Registered into ``FilePreviewDragRegistry`` when a file-preview pasteboard
/// writer begins a drag, then consumed by the pane drop target that accepts it.
public struct FilePreviewDragEntry: Sendable {
    /// Absolute path of the file the drag opens as a preview surface.
    public let filePath: String

    /// Title shown on the dragged tab and the preview surface it opens.
    public let displayTitle: String

    /// Creates a file-preview drag entry.
    /// - Parameters:
    ///   - filePath: absolute path of the dragged file.
    ///   - displayTitle: title shown on the dragged tab.
    public init(filePath: String, displayTitle: String) {
        self.filePath = filePath
        self.displayTitle = displayTitle
    }
}
