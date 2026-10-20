public import Foundation

/// One Files change that Undo can reverse (and Redo can make again).
public enum FileUndoAction: Sendable, Equatable {
    /// `from` was renamed or moved to `to`; undo moves each back.
    case moved([MovedItem])
    /// These items were made (New Folder, Duplicate, Copy); undo trashes them.
    case created([URL])
    /// These items went to the Trash; undo puts them back.
    case trashed([TrashedItem])

    /// One item that changed place.
    public struct MovedItem: Sendable, Equatable {
        /// Where it was.
        public let from: URL
        /// Where it is.
        public let to: URL

        /// Makes a record.
        public init(from: URL, to: URL) {
            self.from = from
            self.to = to
        }
    }
}
