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
    private let now: @Sendable () -> ContinuousClock.Instant
    private var entries: [String: Entry] = [:]
    private var pendingLookups: [String: Task<String?, Never>] = [:]

    /// Bumped by ``removeAll()``. A lookup that started in an older generation
    /// must not write its answer back, because it describes a state the caller
    /// has already been told to forget.
    private var generation = 0

    /// How many callers have been served by joining a lookup already in
    /// flight. Tests assert on this to prove the shared-lookup path ran rather
    /// than inferring it from a call count that a cache hit also satisfies.
    private(set) var joinedPendingLookupCount = 0

    /// Creates a cache over a discovery function.
    ///
    /// - Parameters:
    ///   - entryLifetime: How long a resolved answer stays good.
    ///   - now: Reads the current instant. Defaults to ``ContinuousClock``.
    ///     Tests inject a clock they advance by hand so expiry is exercised
    ///     without sleeping. It comes last so a trailing closure still binds to
    ///     `discover`.
    ///   - discover: Resolves a directory to its GitHub slug. Defaults to
    ///     ``GitMetadataService``.
    public init(
        entryLifetime: Duration = GitHubRepositorySlugCache.defaultEntryLifetime,
        discover: (@Sendable (String) async -> String?)? = nil,
        now: (@Sendable () -> ContinuousClock.Instant)? = nil
    ) {
        self.entryLifetime = entryLifetime
        self.now = now ?? { ContinuousClock().now }
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
        if let entry = entries[directory], now() - entry.resolvedAt < entryLifetime {
            return entry.slug
        }

        if let pending = pendingLookups[directory] {
            joinedPendingLookupCount += 1
            return await pending.value
        }

        let discover = discover
        let task = Task<String?, Never> {
            await discover(directory)
        }
        pendingLookups[directory] = task
        let startedGeneration = generation

        let slug = await task.value

        // `removeAll()` during the lookup means this answer is already stale.
        // Hand it to the caller that asked for it, but do not cache it and do
        // not disturb whatever lookup replaced this one.
        guard startedGeneration == generation else { return slug }

        pendingLookups[directory] = nil
        entries[directory] = Entry(slug: slug, resolvedAt: now())
        return slug
    }

    /// Drops every cached answer, including lookups still in flight.
    ///
    /// A caller already waiting on an in-flight lookup still receives that
    /// lookup's answer, because it asked before the invalidation. Every caller
    /// arriving afterwards resolves afresh.
    public func removeAll() {
        entries.removeAll()
        pendingLookups.removeAll()
        generation &+= 1
    }
}
