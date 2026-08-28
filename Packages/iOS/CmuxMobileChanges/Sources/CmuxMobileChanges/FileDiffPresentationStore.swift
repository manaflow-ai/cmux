/// Render-inert reference store for diff pager page state.
///
/// Deliberately NOT `@Observable`: cache writes (prefetch landings, LRU
/// touches, evictions, scroll-position persistence) must never invalidate a
/// SwiftUI view, because a paging container that re-renders mid-gesture
/// cancels the user's interactive page transition. Pages PULL from this
/// store when they mount; nothing renders FROM it.
@MainActor
public final class FileDiffPresentationStore {
    private var cache: FileDiffPresentationCache
    private var scrollRowIDsByPath: [String: String] = [:]

    /// Creates a store sized for the selected page and its nearby pager pages.
    /// - Parameter maximumEntryCount: Maximum retained page count.
    public init(maximumEntryCount: Int = 7) {
        cache = FileDiffPresentationCache(maximumEntryCount: maximumEntryCount)
    }

    /// Returns and marks one presentation as most recently accessed.
    /// - Parameter path: Repository-relative changed path.
    public func presentation(forPath path: String) -> FileDiffPresentation? {
        cache.presentation(forPath: path)
    }

    /// Inserts or replaces one presentation and evicts least-recently-used pages.
    /// - Parameters:
    ///   - presentation: Default-budget presentation to retain.
    ///   - path: Repository-relative changed path.
    public func insert(_ presentation: FileDiffPresentation, forPath path: String) {
        cache.insert(presentation, forPath: path)
    }

    /// Marks an existing page as most recently accessed.
    /// - Parameter path: Repository-relative changed path.
    public func touch(path: String) {
        cache.touch(path: path)
    }

    /// Paths currently retained, for prefetch-candidate exclusion.
    public var cachedPaths: Set<String> {
        Set(cache.presentations.keys)
    }

    /// Last settled top row for one page, for scroll restore on remount.
    /// - Parameter path: Repository-relative changed path.
    public func scrollRowID(forPath path: String) -> String? {
        scrollRowIDsByPath[path]
    }

    /// Persists the settled top row for one page.
    /// - Parameters:
    ///   - rowID: Row identifier, ignored when nil so a transient unmount
    ///     cannot erase a previously persisted position.
    ///   - path: Repository-relative changed path.
    public func setScrollRowID(_ rowID: String?, forPath path: String) {
        guard let rowID else { return }
        scrollRowIDsByPath[path] = rowID
    }

    /// Removes every retained presentation and scroll position.
    public func removeAll() {
        scrollRowIDsByPath = [:]
        cache.removeAll()
    }
}
