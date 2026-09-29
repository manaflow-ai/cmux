/// The outcome of loading or refreshing one directory.
public struct FileTreeDirectoryUpdate: Sendable, Equatable {
    /// What happened to the directory.
    public enum Outcome: Sendable, Equatable {
        /// The directory listed successfully.
        /// - Parameters:
        ///   - entries: The visible children in display order.
        ///   - diff: The change from the previously delivered children.
        ///   - omittedCount: Entries the provider left out; zero when complete.
        case loaded(entries: [FileTreeEntry], diff: FileTreeChildrenDiff, omittedCount: Int)
        /// The directory could not be listed. Previously delivered children stay.
        /// - Parameter message: A localized, user-presentable reason.
        case failed(message: String)
    }

    /// The directory path.
    public let path: String
    /// Whether this is the first successful delivery for the path.
    public let isInitialLoad: Bool
    /// The result.
    public let outcome: Outcome

    /// Creates an update.
    /// - Parameters:
    ///   - path: The directory path.
    ///   - isInitialLoad: Whether no children were delivered before.
    ///   - outcome: The result.
    public init(path: String, isInitialLoad: Bool, outcome: Outcome) {
        self.path = path
        self.isInitialLoad = isInitialLoad
        self.outcome = outcome
    }
}
