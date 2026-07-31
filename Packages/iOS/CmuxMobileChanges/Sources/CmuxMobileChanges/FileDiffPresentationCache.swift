/// A bounded least-recently-used cache for default-budget diff pages.
public struct FileDiffPresentationCache: Sendable {
    /// Maximum number of page presentations retained at once.
    public let maximumEntryCount: Int
    private var presentationsByPath: [String: FileDiffPresentation] = [:]
    private var pathsByRecency: [String] = []

    /// Creates a cache sized for the selected page and its nearby pager pages.
    /// - Parameter maximumEntryCount: Maximum retained page count.
    public init(maximumEntryCount: Int = 7) {
        precondition(maximumEntryCount > 0)
        self.maximumEntryCount = maximumEntryCount
    }

    /// Immutable presentation values for mounting pager pages.
    public var presentations: [String: FileDiffPresentation] {
        presentationsByPath
    }

    /// Returns and marks one presentation as most recently accessed.
    /// - Parameter path: Repository-relative changed path.
    /// - Returns: The cached presentation, when present.
    public mutating func presentation(forPath path: String) -> FileDiffPresentation? {
        guard let presentation = presentationsByPath[path] else { return nil }
        touch(path: path)
        return presentation
    }

    /// Inserts or replaces one presentation and evicts least-recently-used pages.
    /// - Parameters:
    ///   - presentation: Default-budget presentation to retain.
    ///   - path: Repository-relative changed path.
    public mutating func insert(_ presentation: FileDiffPresentation, forPath path: String) {
        presentationsByPath[path] = presentation
        touch(path: path)
        while pathsByRecency.count > maximumEntryCount {
            let evictedPath = pathsByRecency.removeFirst()
            presentationsByPath.removeValue(forKey: evictedPath)
        }
    }

    /// Marks an existing page as most recently accessed.
    /// - Parameter path: Repository-relative changed path.
    public mutating func touch(path: String) {
        guard presentationsByPath[path] != nil else { return }
        pathsByRecency.removeAll { $0 == path }
        pathsByRecency.append(path)
    }

    /// Removes every retained presentation and recency record.
    public mutating func removeAll() {
        presentationsByPath = [:]
        pathsByRecency = []
    }
}
