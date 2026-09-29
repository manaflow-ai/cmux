/// The complete, unfiltered contents of one directory.
///
/// Providers return every entry, hidden ones included, so toggling hidden
/// files re-filters cached listings instead of repeating I/O.
public struct FileTreeListing: Sendable, Equatable {
    /// The entries in provider order. The engine sorts them.
    public var entries: [FileTreeEntry]
    /// The number of entries the provider omitted to stay within its limit.
    ///
    /// Zero for a complete listing. Remote providers cap very large directories
    /// so one listing cannot exhaust a transport's output limit.
    public var omittedCount: Int

    /// Creates a listing.
    /// - Parameters:
    ///   - entries: The entries in any order.
    ///   - omittedCount: How many entries the provider left out; zero when complete.
    public init(entries: [FileTreeEntry], omittedCount: Int = 0) {
        self.entries = entries
        self.omittedCount = omittedCount
    }
}
