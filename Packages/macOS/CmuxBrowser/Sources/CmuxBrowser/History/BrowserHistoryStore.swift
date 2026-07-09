public import Foundation
public import Combine

/// The single in-memory owner of persisted browsing history, backing the omnibar
/// suggestion list and the History UI.
///
/// `@MainActor` because every mutation runs on the main thread (the `entries`
/// setter drops the derived suggestion cache as its sole invalidation point) and
/// the type is observed by SwiftUI. Pure suggestion matching/scoring and on-disk
/// persistence live in `BrowserHistorySuggestionEngine` / `BrowserHistoryFileRepository`;
/// this store owns only the `@Published` entry list, the first-load lifecycle,
/// and the debounced-save scheduling.
///
/// Kept `ObservableObject` + `@Published` rather than `@Observable` to preserve
/// byte-identical SwiftUI observation for its existing consumers; the
/// `@Observable` migration is behavior-affecting and belongs in a dedicated
/// follow-up, not this faithful relocation.
@MainActor
public final class BrowserHistoryStore: ObservableObject {
    public static let shared = BrowserHistoryStore()

    /// Persisted history record alias, keeping existing
    /// `BrowserHistoryStore.Entry` call sites byte-identical.
    public typealias Entry = BrowserHistoryEntry

    // Single source of truth for history. `private(set)` + `@MainActor` means
    // every mutation runs through this setter, so dropping the derived
    // suggestion cache here is the one enforced invalidation point. Setting it
    // to nil both frees the retained Entry/URL strings promptly (so clearing
    // history does not leave browsing history resident in the cache) and forces
    // a rebuild on next use. It must stay `@Published` for SwiftUI observation.
    // Do not add a writer that bypasses this setter (e.g. an unsafe-buffer bulk
    // write or an external `Binding<[Entry]>`) without dropping the cache.
    @Published public private(set) var entries: [Entry] = [] {
        didSet { cachedSuggestionCandidates = nil }
    }

    private let fileURL: URL?
    private var didLoad: Bool = false
    private var saveTask: Task<Void, Never>?
    private let maxEntries: Int = 5000
    private let saveDebounceNanoseconds: UInt64 = 120_000_000

    // Pure suggestion matching/scoring and persistence I/O live in the engine /
    // file repository; the store owns only the @Published entry list, the
    // first-load lifecycle, and the debounced-save scheduling.
    private let suggestionEngine = BrowserHistorySuggestionEngine()
    private let fileRepository = BrowserHistoryFileRepository()

    public var isLoaded: Bool {
        didLoad
    }

    private typealias SuggestionCandidate = BrowserHistorySuggestionCandidate

    private struct ScoredSuggestion {
        let entry: Entry
        let score: Double
    }

    // Lazily built, lowercased/parsed match fields for every entry. Building a
    // SuggestionCandidate parses the URL (URLComponents) and lowercases five
    // fields; doing that for all entries on every omnibar keystroke pegged the
    // main thread once history grew to a few thousand rows (the typing
    // beachball). `nil` means "not built / just invalidated"; it is rebuilt only
    // when `entries` changes (via the didSet above), so steady-state typing
    // reuses it and pays only the cheap substring scoring in `suggestionScore`.
    private var cachedSuggestionCandidates: [SuggestionCandidate]?

    /// Number of suggestion candidates currently resident in the cache, or 0
    /// when the cache has been invalidated. Used by tests to verify that
    /// clearing history drops the retained candidates promptly.
    public var residentSuggestionCandidateCount: Int { cachedSuggestionCandidates?.count ?? 0 }

    private func suggestionCandidates() -> [SuggestionCandidate] {
        if let cached = cachedSuggestionCandidates { return cached }
        let built = entries.map(suggestionEngine.candidate(for:))
        cachedSuggestionCandidates = built
        return built
    }

    public init(fileURL: URL? = nil) {
        // Avoid calling @MainActor-isolated static methods from default argument context.
        self.fileURL = fileURL ?? BrowserHistoryStore.defaultHistoryFileURL()
    }

    public func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true; if let seededEntries = BrowserHistoryStore.uiTestSeedEntriesIfConfigured() { entries = seededEntries.sorted { $0.lastVisited > $1.lastVisited }; return }
        guard let fileURL else { return }
        migrateLegacyTaggedHistoryFileIfNeeded(to: fileURL)

        // Load synchronously on first access so the first omnibar query can use
        // persisted history immediately (important for deterministic UI behavior).
        guard let decoded = fileRepository.loadSnapshot(from: fileURL) else {
            return
        }

        // Most-recent first.
        entries = decoded.sorted(by: { $0.lastVisited > $1.lastVisited })

        // Remove entries with invalid hosts (no TLD), e.g. "https://news."
        let beforeCount = entries.count
        entries.removeAll { entry in
            guard let url = URL(string: entry.url),
                  let host = url.host?.lowercased() else { return false }
            let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
            return !trimmed.contains(".")
        }
        if entries.count != beforeCount {
            scheduleSave()
        }
    }

    public func recordVisit(url: URL?, title: String?) {
        loadIfNeeded()

        guard let url else { return }
        guard !url.isTemporaryBrowserHistory else { return }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        // Skip URLs whose host lacks a TLD (e.g. "https://news.").
        if let host = url.host?.lowercased() {
            let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
            if !trimmed.contains(".") { return }
        }

        let urlString = url.absoluteString
        guard urlString != "about:blank" else { return }
        let normalizedKey = suggestionEngine.normalizedHistoryKey(url: url)

        if let idx = entries.firstIndex(where: {
            if $0.url == urlString { return true }
            return suggestionEngine.normalizedHistoryKey(urlString: $0.url) == normalizedKey
        }) {
            entries[idx].lastVisited = Date()
            entries[idx].visitCount += 1
            // Prefer non-empty titles, but don't clobber an existing title with empty/whitespace.
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries[idx].title = title
            }
        } else {
            entries.insert(Entry(
                id: UUID(),
                url: urlString,
                title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
                lastVisited: Date(),
                visitCount: 1
            ), at: 0)
        }

        // Keep most-recent first and bound size.
        entries.sort(by: { $0.lastVisited > $1.lastVisited })
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }

        scheduleSave()
    }

    public func recordTypedNavigation(url: URL?) {
        loadIfNeeded()

        guard let url else { return }
        guard !url.isTemporaryBrowserHistory else { return }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        // Skip URLs whose host lacks a TLD (e.g. "https://news.").
        if let host = url.host?.lowercased() {
            let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
            if !trimmed.contains(".") { return }
        }

        let urlString = url.absoluteString
        guard urlString != "about:blank" else { return }

        let now = Date()
        let normalizedKey = suggestionEngine.normalizedHistoryKey(url: url)
        if let idx = entries.firstIndex(where: {
            if $0.url == urlString { return true }
            return suggestionEngine.normalizedHistoryKey(urlString: $0.url) == normalizedKey
        }) {
            entries[idx].typedCount += 1
            entries[idx].lastTypedAt = now
            entries[idx].lastVisited = now
        } else {
            entries.insert(Entry(
                id: UUID(),
                url: urlString,
                title: nil,
                lastVisited: now,
                visitCount: 1,
                typedCount: 1,
                lastTypedAt: now
            ), at: 0)
        }

        entries.sort(by: { $0.lastVisited > $1.lastVisited })
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }

        scheduleSave()
    }

    public func suggestions(for input: String, limit: Int = 10) -> [Entry] {
        loadIfNeeded()
        guard limit > 0 else { return [] }

        let q = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let queryTokens = suggestionEngine.tokenize(query: q)
        let now = Date()

        let matched = suggestionCandidates().compactMap { candidate -> ScoredSuggestion? in
            guard let score = suggestionEngine.score(candidate: candidate, query: q, queryTokens: queryTokens, now: now) else {
                return nil
            }
            return ScoredSuggestion(entry: candidate.entry, score: score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.entry.lastVisited != rhs.entry.lastVisited { return lhs.entry.lastVisited > rhs.entry.lastVisited }
            if lhs.entry.visitCount != rhs.entry.visitCount { return lhs.entry.visitCount > rhs.entry.visitCount }
            return lhs.entry.url < rhs.entry.url
        }

        if matched.count <= limit { return matched.map(\.entry) }
        return Array(matched.prefix(limit).map(\.entry))
    }

    public func recentSuggestions(limit: Int = 10) -> [Entry] {
        loadIfNeeded()
        guard limit > 0 else { return [] }

        let ranked = entries.sorted { lhs, rhs in
            if lhs.typedCount != rhs.typedCount { return lhs.typedCount > rhs.typedCount }
            let lhsTypedDate = lhs.lastTypedAt ?? .distantPast
            let rhsTypedDate = rhs.lastTypedAt ?? .distantPast
            if lhsTypedDate != rhsTypedDate { return lhsTypedDate > rhsTypedDate }
            if lhs.lastVisited != rhs.lastVisited { return lhs.lastVisited > rhs.lastVisited }
            if lhs.visitCount != rhs.visitCount { return lhs.visitCount > rhs.visitCount }
            return lhs.url < rhs.url
        }

        if ranked.count <= limit { return ranked }
        return Array(ranked.prefix(limit))
    }

    @discardableResult
    public func mergeImportedEntries(_ importedEntries: [Entry]) -> Int {
        loadIfNeeded()
        guard !importedEntries.isEmpty else { return 0 }

        var mergedCount = 0
        for imported in importedEntries {
            guard let parsedURL = URL(string: imported.url),
                  let scheme = parsedURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                continue
            }

            if let host = parsedURL.host?.lowercased() {
                let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
                if !trimmed.contains(".") { continue }
            }

            let urlString = parsedURL.absoluteString
            guard urlString != "about:blank" else { continue }
            let normalizedKey = suggestionEngine.normalizedHistoryKey(url: parsedURL)

            let importedTitle = imported.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let importedLastVisited = imported.lastVisited
            let importedVisitCount = max(1, imported.visitCount)
            let importedTypedCount = max(0, imported.typedCount)
            let importedLastTypedAt = imported.lastTypedAt

            if let idx = entries.firstIndex(where: {
                if $0.url == urlString { return true }
                guard let normalizedKey else { return false }
                return suggestionEngine.normalizedHistoryKey(urlString: $0.url) == normalizedKey
            }) {
                var didMutate = false
                if importedLastVisited > entries[idx].lastVisited {
                    entries[idx].lastVisited = importedLastVisited
                    didMutate = true
                }
                if importedVisitCount > entries[idx].visitCount {
                    entries[idx].visitCount = importedVisitCount
                    didMutate = true
                }
                if importedTypedCount > entries[idx].typedCount {
                    entries[idx].typedCount = importedTypedCount
                    didMutate = true
                }
                if let importedLastTypedAt {
                    if let existingLastTypedAt = entries[idx].lastTypedAt {
                        if importedLastTypedAt > existingLastTypedAt {
                            entries[idx].lastTypedAt = importedLastTypedAt
                            didMutate = true
                        }
                    } else {
                        entries[idx].lastTypedAt = importedLastTypedAt
                        didMutate = true
                    }
                }

                let existingTitle = entries[idx].title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let incomingTitle = importedTitle ?? ""
                if !incomingTitle.isEmpty,
                   (existingTitle.isEmpty || importedLastVisited >= entries[idx].lastVisited) {
                    if entries[idx].title != incomingTitle {
                        entries[idx].title = incomingTitle
                        didMutate = true
                    }
                }

                if didMutate {
                    mergedCount += 1
                }
            } else {
                entries.append(Entry(
                    id: UUID(),
                    url: urlString,
                    title: importedTitle,
                    lastVisited: importedLastVisited,
                    visitCount: importedVisitCount,
                    typedCount: importedTypedCount,
                    lastTypedAt: importedLastTypedAt
                ))
                mergedCount += 1
            }
        }

        guard mergedCount > 0 else { return 0 }
        entries.sort(by: { $0.lastVisited > $1.lastVisited })
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        scheduleSave()
        return mergedCount
    }

    public func clearHistory() {
        loadIfNeeded()
        saveTask?.cancel()
        saveTask = nil
        entries = []
        guard let fileURL else { return }
        fileRepository.removeFile(at: fileURL)
    }

    public func clearHistoryWithoutLoadingPersistedFile() {
        saveTask?.cancel()
        saveTask = nil
        didLoad = true
        entries = []
    }

    public func cancelPendingSaves() {
        saveTask?.cancel()
        saveTask = nil
    }

    @discardableResult
    public func removeHistoryEntry(urlString: String) -> Bool {
        loadIfNeeded()
        let normalized = suggestionEngine.normalizedHistoryKey(urlString: urlString)
        let originalCount = entries.count
        entries.removeAll { entry in
            if entry.url == urlString { return true }
            guard let normalized else { return false }
            return suggestionEngine.normalizedHistoryKey(urlString: entry.url) == normalized
        }
        let didRemove = entries.count != originalCount
        if didRemove {
            scheduleSave()
        }
        return didRemove
    }

    public func flushPendingSaves() {
        loadIfNeeded()
        saveTask?.cancel()
        saveTask = nil
        guard let fileURL else { return }
        try? BrowserHistoryFileRepository.persist(entries, to: fileURL)
    }

    private func scheduleSave() {
        guard let fileURL else { return }

        saveTask?.cancel()
        let snapshot = entries
        let debounceNanoseconds = saveDebounceNanoseconds

        saveTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds) // debounce
            } catch {
                return
            }
            if Task.isCancelled { return }

            do {
                try BrowserHistoryFileRepository.persist(snapshot, to: fileURL)
            } catch {
                return
            }
        }
    }

    private func migrateLegacyTaggedHistoryFileIfNeeded(to targetURL: URL) {
        fileRepository.migrateLegacyFileIfNeeded(
            legacyURL: Self.location()?.legacyTaggedHistoryFileURL,
            to: targetURL
        )
    }

    /// Builds the location resolver from the live Application Support directory
    /// and process bundle identifier, or `nil` when Application Support is
    /// unavailable (matching the prior `defaultHistoryFileURL` nil path).
    nonisolated private static func location() -> BrowserHistoryLocation? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "cmux"
        return BrowserHistoryLocation(applicationSupportDirectory: appSupport, bundleIdentifier: bundleId)
    }

    nonisolated private static func defaultHistoryFileURL() -> URL? {
        location()?.historyFileURL
    }

    public nonisolated static func defaultHistoryFileURLForCurrentBundle() -> URL? {
        defaultHistoryFileURL()
    }

    public nonisolated static func normalizedBrowserHistoryNamespaceForBundleIdentifier(_ bundleIdentifier: String) -> String {
        BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: bundleIdentifier)
    }

    /// Decodes the UI-test history seed from the environment when the harness has
    /// configured one, so first load presents a deterministic history list. `nil`
    /// outside UI-test mode. Folded in from the app-side performance-support
    /// extension during the package relocation; it is pure
    /// (`ProcessInfo` + `JSONDecoder`) with no app-target coupling.
    private static func uiTestSeedEntriesIfConfigured() -> [Entry]? {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_MODE"] == "1",
              let rawSeed = env["CMUX_UI_TEST_BROWSER_HISTORY_JSON"],
              let data = rawSeed.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([Entry].self, from: data)
    }
}
