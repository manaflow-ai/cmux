import Foundation

/// A change to rows a ``PagedListSource`` already served, as it happens (a live list: new rows,
/// edits, rows inserted in the middle, removals, moves). Positions are by id in newest-first order;
/// a change about rows the list hasn't read (outside its loaded pages) is dropped, and the row shows
/// with its current value when its page is read.
public enum PagedListChange<Item: Identifiable & Sendable>: Sendable where Item.ID: Sendable {
    /// Rows that arrived at the newest end (newest first). A row already shown moves there.
    case newest([Item])
    /// Rows inserted right after (older than) `after`, newest first.
    case insert([Item], after: Item.ID)
    /// New values for rows shown, in place.
    case update([Item])
    case remove([Item.ID])
    /// A row moved right after (older than) `after`, or to the newest end (nil).
    case move(Item.ID, after: Item.ID?)
}

/// Where a ``PagedListModel`` reads from: pages by cursor and, for a live list, its changes. Screens
/// adapt their backend to it; tests and the stress bench inject a mock (dependency injection), so the
/// same list is measured under any load (verify/paged-list.md, "Stress bench").
@MainActor
public protocol PagedListSource<Item>: AnyObject {
    associatedtype Item: Identifiable & Equatable & Sendable where Item.ID: Sendable
    /// The page after `cursor` (nil: the first, newest page).
    func page(after cursor: String?) async throws -> PagedListPage<Item>
    /// The changes to rows already served, in order, until the stream ends. A source that never
    /// changes returns a finished stream.
    func changes() -> AsyncStream<[PagedListChange<Item>]>
}

extension PagedListSource {
    public func changes() -> AsyncStream<[PagedListChange<Item>]> { AsyncStream { $0.finish() } }
}
