import Foundation

/// Maintains UTF-16 line starts for an editable File Preview buffer.
public struct FilePreviewLineIndex: Sendable {
    var storage: FilePreviewLineIndexStorage
    /// The current UTF-16 length of the indexed buffer.
    public internal(set) var loadedUTF16Length: Int

    /// The number of logical lines in the indexed buffer.
    public var lineCount: Int {
        storage.lineCount
    }

    /// Creates an index by scanning `string` once.
    ///
    /// - Parameter string: The UTF-16 text represented by the index.
    public init(string: String) {
        var storage = FilePreviewLineIndexStorage()
        loadedUTF16Length = storage.appendLineStarts(from: string)
        self.storage = storage
    }

    /// The indexed line starts, materialized for diagnostics and tests.
    ///
    /// The gutter uses ``offset(forLine:)`` and ``lineNumber(containingUTF16Offset:)``
    /// so drawing and editing do not allocate this array.
    internal var lineStartOffsets: [Int] {
        storage.values()
    }
}
