public import Foundation

/// A pending file-preview drag payload: the file being dragged plus the title
/// shown for it. Stored in `FilePreviewDragRegistry` keyed by a `UUID` while a
/// drag is in flight and consumed when the drop is resolved.
public struct FilePreviewDragEntry {
    /// Absolute path of the file backing the drag.
    public let filePath: String
    /// Human-readable title displayed for the dragged item.
    public let displayTitle: String

    /// Creates a drag entry for `filePath` shown as `displayTitle`.
    public init(filePath: String, displayTitle: String) {
        self.filePath = filePath
        self.displayTitle = displayTitle
    }
}
