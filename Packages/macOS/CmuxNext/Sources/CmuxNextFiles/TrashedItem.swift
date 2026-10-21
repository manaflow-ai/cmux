public import Foundation

/// An item moved to the Trash: where it was and where it went, for Put Back and Undo.
public struct TrashedItem: Sendable, Hashable {
    /// Where the item was.
    public let original: URL
    /// Where it is in the Trash.
    public let trashed: URL

    /// Makes a record.
    public init(original: URL, trashed: URL) {
        self.original = original
        self.trashed = trashed
    }
}
