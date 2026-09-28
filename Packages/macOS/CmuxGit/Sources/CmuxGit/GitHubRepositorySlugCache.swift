/// Caches the GitHub `owner/name` repository behind a directory.
///
/// Repository discovery reads `git` configuration and can fall back to running
/// `git`, which is far too much work for an interactive path that asks "which
/// repository is this pane in?" on every pointer event. Entries are resolved
/// once per directory and shared by concurrent callers.
///
/// Entries expire so a remote added after cmux launched is picked up without a
/// restart, and so a directory that was not a repository yet does not stay that
/// way forever.
///
/// The first slug wins, which is ``GitMetadataService/repositorySlugs(forDirectory:)``
/// ordering: `upstream`, then `origin`, then the rest.
public actor GitHubRepositorySlugCache {
    /// The process-wide cache.
    public static let shared = GitHubRepositorySlugCache()

    /// How long a resolved answer stays good.
    public static let defaultEntryLifetime: Duration = .seconds(600)

    private struct Entry {
        let slug: String?
        let resolvedAt: ContinuousClock.Instant
    }

    private let discover: @Sendable (String) async -> String?
    private let entryLifetime: Duration
    private let clock = ContinuousClock()
    private var entries: [String: Entry] = [:]
    private var pendingLookups: [String: Task<String?, Never>] = [:]

    /// Creates a cache over a discovery function.
    ///
    /// - Parameters:
    ///   - entryLifetime: How long a resolved answer stays good.
    ///   - discover: Resolves a directory to its GitHub slug. Defaults to
    ///     ``GitMetadataService``.
    public init(
        entryLifetime: Duration = GitHubRepositorySlugCache.defaultEntryLifetime,
        discover: (@Sendable (String) async -> String?)? = nil
    ) {
        self.entryLifetime = entryLifetime
        self.discover = discover ?? { directory in
            await GitMetadataService().repositorySlugs(forDirectory: directory).first
        }
    }

    /// The GitHub repository enclosing a directory.
    ///
    /// Concurrent callers for the same directory share one lookup.
    ///
    /// - Parameter directory: An absolute path to inspect.
    /// - Returns: The `owner/name` slug, or `nil` when the directory is not in a
    ///   repository with a GitHub remote.
    public func slug(forDirectory directory: String) async -> String? {
        if let entry = entries[directory], clock.now - entry.resolvedAt < entryLifetime {
            return entry.slug
        }

        if let pending = pendingLookups[directory] {
            return await pending.value
        }

        let discover = discover
        let task = Task<String?, Never> {
            await discover(directory)
        }
        pendingLookups[directory] = task

        let slug = await task.value
        pendingLookups[directory] = nil
        entries[directory] = Entry(slug: slug, resolvedAt: clock.now)
        return slug
    }

    /// Drops every cached answer.
    public func removeAll() {
        entries.removeAll()
    }
}
