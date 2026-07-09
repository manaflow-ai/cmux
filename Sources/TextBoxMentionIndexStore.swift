import CmuxFoundation
import Foundation

actor TextBoxMentionIndexStore {
    static let shared = TextBoxMentionIndexStore()

    private static let fileIndexTTL: TimeInterval = 30
    private static let maxCachedFileIndexes = 8
    private static let suggestionLimit = 500

    private let skillScanner = TextBoxMentionSkillScanner()
    private let fileSystemScanner = TextBoxMentionFileSystemScanner()

    private var fileIndexesByRoot: [String: TextBoxMentionCachedIndex] = [:]
    private var fileIndexRefreshTasks: [String: TextBoxMentionFileIndexRefreshTask] = [:]
    private var nextFileIndexRefreshTaskID: UInt64 = 0
    private var skillIndexesByRootKey: [String: TextBoxMentionCandidateIndex] = [:]

    func suggestions(
        for query: TextBoxMentionQuery,
        rootDirectory: String?
    ) async -> [TextBoxMentionSuggestion] {
        switch query.kind {
        case .file:
            guard let rootDirectory = rootDirectory?.canonicalDirectoryPath() else { return [] }
            return await fileSuggestions(for: query, rootDirectory: rootDirectory)
        case .skill:
            let index = skillIndex(rootDirectory: rootDirectory?.canonicalDirectoryPath())
            return index.rankedCandidates(
                matching: query.query,
                limit: Self.suggestionLimit,
                shouldCancel: { Task.isCancelled }
            )
                .map { $0.suggestion(trigger: query.trigger) }
        }
    }

    func warmIndexes(rootDirectory: String?) async {
        let normalizedRootDirectory = rootDirectory?.canonicalDirectoryPath()
        _ = skillIndex(rootDirectory: normalizedRootDirectory)
        if let normalizedRootDirectory {
            _ = await fileIndex(rootDirectory: normalizedRootDirectory, now: Date())
        }
    }

    private func fileSuggestions(
        for query: TextBoxMentionQuery,
        rootDirectory: String
    ) async -> [TextBoxMentionSuggestion] {
        let now = Date()
        let trimmedQuery = query.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            if let cachedIndex = cachedFileIndex(rootDirectory: rootDirectory, now: now) {
                return cachedIndex.rankedCandidates(
                    matching: query.query,
                    limit: Self.suggestionLimit,
                    shouldCancel: { Task.isCancelled }
                )
                .map { $0.suggestion(trigger: query.trigger) }
            }

            refreshFileIndexInBackground(rootDirectory: rootDirectory, now: now)
            return await fileSystemScanner.scanRootFileSystemCandidates(rootURL: URL(
                fileURLWithPath: rootDirectory,
                isDirectory: true
            ))
            .prefix(Self.suggestionLimit)
            .map { $0.suggestion(trigger: query.trigger) }
        }

        let index = await fileIndex(rootDirectory: rootDirectory, now: now)
        if Task.isCancelled { return [] }

        var matches = index.rankedCandidates(
            matching: query.query,
            limit: Self.suggestionLimit,
            shouldCancel: { Task.isCancelled }
        )
        if Task.isCancelled { return [] }
        if matches.isEmpty {
            let refreshed = await refreshFileIndex(
                rootDirectory: rootDirectory,
                now: Date(),
                minimumStartedAt: now
            )
            if Task.isCancelled { return [] }
            matches = refreshed.rankedCandidates(
                matching: query.query,
                limit: Self.suggestionLimit,
                shouldCancel: { Task.isCancelled }
            )
            if Task.isCancelled { return [] }
        }
        return matches
            .map { $0.suggestion(trigger: query.trigger) }
    }

    private func cachedFileIndex(
        rootDirectory: String,
        now: Date
    ) -> TextBoxMentionCandidateIndex? {
        guard let cached = fileIndexesByRoot[rootDirectory] else {
            pruneFileIndexCache(now: now)
            return nil
        }
        guard now.timeIntervalSince(cached.createdAt) < Self.fileIndexTTL else {
            fileIndexesByRoot[rootDirectory] = nil
            pruneFileIndexCache(now: now)
            return nil
        }
        fileIndexesByRoot[rootDirectory] = TextBoxMentionCachedIndex(
            index: cached.index,
            createdAt: cached.createdAt,
            lastAccessedAt: now,
            refreshStartedAt: cached.refreshStartedAt
        )
        pruneFileIndexCache(now: now)
        return cached.index
    }

    private func fileIndex(
        rootDirectory: String,
        now: Date
    ) async -> TextBoxMentionCandidateIndex {
        if let cachedIndex = cachedFileIndex(rootDirectory: rootDirectory, now: now) {
            return cachedIndex
        }
        return await refreshFileIndex(rootDirectory: rootDirectory, now: now)
    }

    private func refreshFileIndex(
        rootDirectory: String,
        now: Date,
        minimumStartedAt: Date? = nil
    ) async -> TextBoxMentionCandidateIndex {
        // Coalesce concurrent refreshes: while one scan is in flight for a root,
        // additional keystrokes await the same scan instead of each spawning a
        // fresh (and expensive) `rg`/filesystem walk. The detached scan is not
        // cancelled, so a join here is correct even if the caller's lookup task is.
        let refreshTask = fileIndexRefreshTask(
            rootDirectory: rootDirectory,
            minimumStartedAt: minimumStartedAt
        )
        let index = await refreshTask.task.value
        storeFileIndex(
            rootDirectory: rootDirectory,
            index: index,
            refreshStartedAt: refreshTask.startedAt,
            refreshTaskID: refreshTask.id
        )
        return index
    }

    private func refreshFileIndexInBackground(rootDirectory: String, now: Date) {
        guard cachedFileIndex(rootDirectory: rootDirectory, now: now) == nil else { return }
        let refreshTask = fileIndexRefreshTask(rootDirectory: rootDirectory)
        Task { [rootDirectory, refreshTask] in
            let index = await refreshTask.task.value
            self.storeFileIndex(
                rootDirectory: rootDirectory,
                index: index,
                refreshStartedAt: refreshTask.startedAt,
                refreshTaskID: refreshTask.id
            )
        }
    }

    private func fileIndexRefreshTask(
        rootDirectory: String,
        minimumStartedAt: Date? = nil
    ) -> TextBoxMentionFileIndexRefreshTask {
        if let inFlight = fileIndexRefreshTasks[rootDirectory],
           minimumStartedAt.map({ inFlight.startedAt >= $0 }) ?? true {
            return inFlight
        }

        let rootURL = URL(fileURLWithPath: rootDirectory, isDirectory: true)
        let scanTask = Task<TextBoxMentionCandidateIndex, Never>.detached(priority: .utility) { [fileSystemScanner] in
            let candidates = await fileSystemScanner.scanFiles(rootURL: rootURL)
            return TextBoxMentionCandidateIndex(candidates: candidates)
        }
        nextFileIndexRefreshTaskID &+= 1
        let refreshTask = TextBoxMentionFileIndexRefreshTask(
            id: nextFileIndexRefreshTaskID,
            startedAt: Date(),
            task: scanTask
        )
        fileIndexRefreshTasks[rootDirectory] = refreshTask
        return refreshTask
    }

    private func storeFileIndex(
        rootDirectory: String,
        index: TextBoxMentionCandidateIndex,
        refreshStartedAt: Date,
        refreshTaskID: UInt64
    ) {
        if let cached = fileIndexesByRoot[rootDirectory],
           cached.refreshStartedAt > refreshStartedAt {
            return
        }
        if fileIndexRefreshTasks[rootDirectory]?.id == refreshTaskID {
            fileIndexRefreshTasks[rootDirectory] = nil
        }
        let storedAt = Date()
        fileIndexesByRoot[rootDirectory] = TextBoxMentionCachedIndex(
            index: index,
            createdAt: storedAt,
            lastAccessedAt: storedAt,
            refreshStartedAt: refreshStartedAt
        )
        pruneFileIndexCache(now: storedAt)
    }

    private func pruneFileIndexCache(now: Date) {
        let expiredRoots = fileIndexesByRoot.compactMap { rootDirectory, cached in
            now.timeIntervalSince(cached.createdAt) >= Self.fileIndexTTL ? rootDirectory : nil
        }
        for rootDirectory in expiredRoots {
            fileIndexesByRoot[rootDirectory] = nil
        }

        guard fileIndexesByRoot.count > Self.maxCachedFileIndexes else { return }
        let rootsToRemove = fileIndexesByRoot
            .sorted { lhs, rhs in
                if lhs.value.lastAccessedAt != rhs.value.lastAccessedAt {
                    return lhs.value.lastAccessedAt < rhs.value.lastAccessedAt
                }
                return lhs.key < rhs.key
            }
            .prefix(fileIndexesByRoot.count - Self.maxCachedFileIndexes)
            .map(\.key)
        for rootDirectory in rootsToRemove {
            fileIndexesByRoot[rootDirectory] = nil
        }
    }

    private func skillIndex(rootDirectory: String?) -> TextBoxMentionCandidateIndex {
        let roots = skillScanner.searchRoots(rootDirectory: rootDirectory)
        let cacheKey = roots.map(\.path).joined(separator: "\n")
        if let cached = skillIndexesByRootKey[cacheKey] {
            return cached
        }

        let index = TextBoxMentionCandidateIndex(candidates: skillScanner.candidates(inRoots: roots))
        skillIndexesByRootKey[cacheKey] = index
        return index
    }
}
