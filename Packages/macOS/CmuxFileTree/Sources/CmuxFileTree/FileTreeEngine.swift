/// Loads, caches, sorts and diffs directory listings off the main actor.
///
/// One engine serves one root on one provider. The main actor owns row
/// objects and expansion; the engine owns raw listings and the last visible
/// child list it delivered per directory, so every delivery carries an
/// incremental ``FileTreeChildrenDiff`` instead of a reload. Toggling hidden
/// files or the sort order re-derives cached listings without I/O.
///
/// ```swift
/// let engine = FileTreeEngine(provider: LocalFileTreeProvider())
/// let updates = await engine.load(["/Users/me/project"])
/// ```
public actor FileTreeEngine {
    private let provider: any FileTreeProvider
    private var sortOrder: FileTreeSortOrder
    private var showsHiddenFiles: Bool
    /// Raw listings as the provider returned them, by directory path.
    private var listings: [String: FileTreeListing] = [:]
    /// The children last delivered per directory, in display order.
    private var delivered: [String: [FileTreeEntry]] = [:]
    /// Bumped when a load for the path starts; a finishing load whose number
    /// is no longer current lost a race and is dropped.
    private var generations: [String: UInt64] = [:]

    /// Creates an engine.
    /// - Parameters:
    ///   - provider: The filesystem to browse.
    ///   - sortOrder: The initial sibling order.
    ///   - showsHiddenFiles: Whether hidden entries are delivered.
    public init(
        provider: any FileTreeProvider,
        sortOrder: FileTreeSortOrder = .standard,
        showsHiddenFiles: Bool = true
    ) {
        self.provider = provider
        self.sortOrder = sortOrder
        self.showsHiddenFiles = showsHiddenFiles
    }

    /// Lists directories through the provider's batch call and returns one
    /// update per path that finished without being superseded.
    ///
    /// Loading an already-loaded path re-lists it and delivers only the diff.
    /// - Parameter paths: Absolute directory paths.
    /// - Returns: Updates in the order of `paths`.
    public func load(_ paths: [String]) async -> [FileTreeDirectoryUpdate] {
        var unique: [String] = []
        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted {
            unique.append(path)
        }
        guard !unique.isEmpty else { return [] }
        var tickets: [String: UInt64] = [:]
        for path in unique {
            let next = (generations[path] ?? 0) &+ 1
            generations[path] = next
            tickets[path] = next
        }
        let results: [String: Result<FileTreeListing, any Error>]
        if unique.count == 1, let path = unique.first {
            do {
                results = [path: .success(try await provider.listDirectory(at: path))]
            } catch {
                results = [path: .failure(error)]
            }
        } else {
            results = await provider.listDirectories(at: unique)
        }
        if Task.isCancelled { return [] }
        var updates: [FileTreeDirectoryUpdate] = []
        for path in unique {
            guard generations[path] == tickets[path], let result = results[path] else { continue }
            switch result {
            case .success(let listing):
                listings[path] = listing
                updates.append(deliver(path: path))
            case .failure(let error):
                if error is CancellationError { continue }
                updates.append(FileTreeDirectoryUpdate(
                    path: path,
                    isInitialLoad: delivered[path] == nil,
                    outcome: .failed(message: error.localizedDescription)
                ))
            }
        }
        return updates
    }

    /// Changes sorting or hidden-file visibility and re-derives every cached
    /// directory without I/O.
    /// - Parameters:
    ///   - sortOrder: The new sibling order.
    ///   - showsHiddenFiles: Whether hidden entries are delivered.
    /// - Returns: Updates for directories whose visible children changed.
    public func setPresentation(sortOrder: FileTreeSortOrder, showsHiddenFiles: Bool) -> [FileTreeDirectoryUpdate] {
        guard sortOrder != self.sortOrder || showsHiddenFiles != self.showsHiddenFiles else { return [] }
        self.sortOrder = sortOrder
        self.showsHiddenFiles = showsHiddenFiles
        return listings.keys.sorted().compactMap { path in
            let update = deliver(path: path)
            if case .loaded(_, let diff, _) = update.outcome, diff.isEmpty { return nil }
            return update
        }
    }

    /// Forgets cached listings at and below `path`, so the next load of any of
    /// them is an initial load. Call when rows under `path` are discarded.
    /// - Parameter path: The directory whose subtree to forget.
    public func discard(subtreeAt path: String) {
        let prefix = path == "/" ? "/" : path + "/"
        for key in Array(listings.keys) where key == path || key.hasPrefix(prefix) {
            listings[key] = nil
            delivered[key] = nil
            generations[key] = (generations[key] ?? 0) &+ 1
        }
    }

    /// The directories with a cached listing.
    public func loadedDirectories() -> Set<String> {
        Set(listings.keys)
    }

    /// The cached directories a change batch touches.
    ///
    /// Changes inside directories that were never loaded cost only a lookup.
    /// - Parameter batch: A batch from ``FileTreeProvider/changes(under:)``.
    /// - Returns: Loaded directories to refresh.
    public func affectedDirectories(for batch: FileTreeChangeBatch) -> Set<String> {
        var result = Set<String>()
        for directory in batch.directories where listings[directory] != nil {
            result.insert(directory)
        }
        if !batch.subtrees.isEmpty {
            for key in listings.keys {
                for subtree in batch.subtrees {
                    let prefix = subtree == "/" ? "/" : subtree + "/"
                    if key == subtree || key.hasPrefix(prefix) {
                        result.insert(key)
                        break
                    }
                }
            }
        }
        return result
    }

    private func deliver(path: String) -> FileTreeDirectoryUpdate {
        let listing = listings[path] ?? FileTreeListing(entries: [])
        let visibleEntries = showsHiddenFiles ? listing.entries : listing.entries.filter { !$0.isHidden }
        let next = sortOrder.sorted(visibleEntries)
        let previous = delivered[path]
        delivered[path] = next
        return FileTreeDirectoryUpdate(
            path: path,
            isInitialLoad: previous == nil,
            outcome: .loaded(
                entries: next,
                diff: FileTreeChildrenDiff(old: previous ?? [], new: next),
                omittedCount: listing.omittedCount
            )
        )
    }
}
