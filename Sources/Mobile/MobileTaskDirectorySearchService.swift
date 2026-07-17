import Foundation

/// Builds a bounded, short-lived directory index on the Mac and searches it
/// without exposing filesystem traversal to the phone. The index stays warm
/// across keystrokes, never follows symlinks, and skips dependency/cache trees
/// that are both noisy and expensive to enumerate.
actor MobileTaskDirectorySearchService {
    enum SearchError: Error, Equatable {
        case indexTimedOut
        case busy
    }

    struct Configuration: Sendable {
        var maximumDirectories = 12_000
        var maximumDepth = 6
        var cacheLifetime: TimeInterval = 30
        var maximumFilesystemEntries = 24_000
        var indexBuildTimeout: Duration = .seconds(3)
        var maximumConcurrentIndexBuilds = 2
        var maximumForegroundFilesystemEntries = 8_000
    }

    static let shared = MobileTaskDirectorySearchService()

    private struct Snapshot: Sendable {
        let rootIDs: Set<Data>
        let paths: [SearchablePath]
        let builtAt: Date
    }

    private enum BuildOutcome {
        case success([SearchablePath])
        case failure(SearchError)
        case cancelled
    }

    private struct PendingBuild {
        let id: UUID
        let rootIDs: Set<Data>
        var waiters: [UUID: CheckedContinuation<BuildOutcome, Never>]
        var deadlineTask: Task<Void, Never>?
    }

    struct SearchablePath: Sendable {
        let path: String
        let pathBytes: [UInt8]
        let foldedPath: String
        let components: [String]
        let basename: String
    }

    private struct RankedPath {
        let candidate: SearchablePath
        let tier: Int
        let unmatchedComponents: Int
    }

    private struct PendingRank {
        let id: UUID
        let task: Task<[String], Never>
    }

    private struct PendingForegroundSearch {
        let id: UUID
        let task: Task<[String], Never>
    }

    typealias IndexBuilder = @Sendable ([URL], Configuration) async -> [SearchablePath]
    typealias RankOperation = @Sendable ([SearchablePath], String, Int) async -> [String]
    typealias ForegroundSearchOperation = @Sendable ([URL], String, Int, Configuration) async -> [String]
    typealias DeadlineSleep = @Sendable (Duration) async -> Void

    private let homeDirectory: URL
    private let configuration: Configuration
    private let indexBuilder: IndexBuilder
    private let rankOperation: RankOperation
    private let foregroundSearchOperation: ForegroundSearchOperation
    private let deadlineSleep: DeadlineSleep
    private var snapshot: Snapshot?
    private var pendingBuildIDsByRoots: [Set<Data>: UUID] = [:]
    private var pendingBuildsByID: [UUID: PendingBuild] = [:]
    private var activeBuildIDs: Set<UUID> = []
    private var searchRevision: UInt64 = 0
    private var pendingRank: PendingRank?
    private var pendingForegroundSearch: PendingForegroundSearch?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        configuration: Configuration = Configuration(),
        indexBuilder: IndexBuilder? = nil,
        rankOperation: RankOperation? = nil,
        foregroundSearchOperation: ForegroundSearchOperation? = nil,
        deadlineSleep: DeadlineSleep? = nil
    ) {
        precondition(configuration.maximumConcurrentIndexBuilds > 0)
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.configuration = configuration
        self.indexBuilder = indexBuilder ?? { roots, configuration in
            Self.prepare(paths: Self.scan(roots: roots, configuration: configuration))
        }
        self.rankOperation = rankOperation ?? { paths, query, limit in
            Self.rank(searchablePaths: paths, query: query, limit: limit)
        }
        self.foregroundSearchOperation = foregroundSearchOperation ?? { roots, query, limit, configuration in
            Self.exactForegroundMatches(
                roots: roots,
                query: query,
                limit: limit,
                configuration: configuration
            )
        }
        self.deadlineSleep = deadlineSleep ?? { timeout in
            try? await ContinuousClock().sleep(for: timeout)
        }
    }

    func search(
        query rawQuery: String,
        seedPaths: [String],
        limit: Int = 64,
        now: Date = Date()
    ) async throws -> [String] {
        searchRevision &+= 1
        let revision = searchRevision
        pendingRank?.task.cancel()
        pendingForegroundSearch?.task.cancel()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        let expandedQuery = Self.expandHome(query, homeDirectory: homeDirectory.path)
        let maximumResults = min(limit, 64)
        let seededMatches = Self.rank(
            searchablePaths: Self.seedCandidates(
                seedPaths: seedPaths,
                homeDirectory: homeDirectory
            ),
            query: expandedQuery,
            limit: maximumResults
        )
        guard !Task.isCancelled, revision == searchRevision else { return [] }
        if !seededMatches.isEmpty { return seededMatches }

        let roots = Self.searchRoots(homeDirectory: homeDirectory, seedPaths: seedPaths)
        let cachedPaths = cachedPaths(roots: roots, now: now)
        if let cachedPaths {
            let cachedMatches = await rankLatest(
                paths: cachedPaths,
                query: expandedQuery,
                limit: maximumResults,
                revision: revision
            )
            guard !Task.isCancelled, revision == searchRevision else { return [] }
            if !cachedMatches.isEmpty { return cachedMatches }
        } else {
            ensureIndexBuildStarted(roots: roots, builtAt: now)
        }

        let foregroundMatches = await foregroundMatchesLatest(
            roots: Self.foregroundSearchRoots(homeDirectory: homeDirectory, seedPaths: seedPaths),
            query: expandedQuery,
            limit: maximumResults,
            revision: revision
        )
        guard !Task.isCancelled, revision == searchRevision else { return [] }
        if !foregroundMatches.isEmpty { return foregroundMatches }
        if cachedPaths != nil { return [] }

        let paths = try await indexedPaths(roots: roots, now: now)
        guard !Task.isCancelled, revision == searchRevision else { return [] }
        return await rankLatest(
            paths: paths,
            query: expandedQuery,
            limit: maximumResults,
            revision: revision
        )
    }

    private func indexedPaths(roots: [URL], now: Date) async throws -> [SearchablePath] {
        let rootIDs = Set(roots.map { Data($0.path.utf8) })
        if let cachedPaths = cachedPaths(rootIDs: rootIDs, now: now) { return cachedPaths }
        guard !Task.isCancelled else { throw CancellationError() }
        let waiterID = UUID()
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerBuildWaiter(
                    waiterID: waiterID,
                    roots: roots,
                    rootIDs: rootIDs,
                    builtAt: now,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelBuildWaiter(waiterID, rootIDs: rootIDs) }
        }
        switch outcome {
        case let .success(paths):
            return paths
        case let .failure(error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
    }

    private func cachedPaths(roots: [URL], now: Date) -> [SearchablePath]? {
        cachedPaths(rootIDs: Set(roots.map { Data($0.path.utf8) }), now: now)
    }

    private func cachedPaths(rootIDs: Set<Data>, now: Date) -> [SearchablePath]? {
        guard let snapshot,
              now.timeIntervalSince(snapshot.builtAt) < configuration.cacheLifetime,
              rootIDs == snapshot.rootIDs else { return nil }
        return snapshot.paths
    }

    private func ensureIndexBuildStarted(roots: [URL], builtAt: Date) {
        let rootIDs = Set(roots.map { Data($0.path.utf8) })
        guard cachedPaths(rootIDs: rootIDs, now: builtAt) == nil,
              pendingBuildIDsByRoots[rootIDs] == nil,
              activeBuildIDs.count < configuration.maximumConcurrentIndexBuilds else { return }
        launchIndexBuild(roots: roots, rootIDs: rootIDs, builtAt: builtAt, waiters: [:])
    }

    private func registerBuildWaiter(
        waiterID: UUID,
        roots: [URL],
        rootIDs: Set<Data>,
        builtAt: Date,
        continuation: CheckedContinuation<BuildOutcome, Never>
    ) {
        if let buildID = pendingBuildIDsByRoots[rootIDs],
           var build = pendingBuildsByID[buildID] {
            build.waiters[waiterID] = continuation
            if build.deadlineTask == nil {
                build.deadlineTask = makeBuildDeadlineTask(buildID)
            }
            pendingBuildsByID[buildID] = build
            return
        }
        guard activeBuildIDs.count < configuration.maximumConcurrentIndexBuilds else {
            continuation.resume(returning: .failure(.busy))
            return
        }

        launchIndexBuild(
            roots: roots,
            rootIDs: rootIDs,
            builtAt: builtAt,
            waiters: [waiterID: continuation]
        )
    }

    private func launchIndexBuild(
        roots: [URL],
        rootIDs: Set<Data>,
        builtAt: Date,
        waiters: [UUID: CheckedContinuation<BuildOutcome, Never>]
    ) {
        let buildID = UUID()
        pendingBuildsByID[buildID] = PendingBuild(
            id: buildID,
            rootIDs: rootIDs,
            waiters: waiters,
            deadlineTask: waiters.isEmpty ? nil : makeBuildDeadlineTask(buildID)
        )
        pendingBuildIDsByRoots[rootIDs] = buildID
        activeBuildIDs.insert(buildID)
        let configuration = configuration
        Task.detached(priority: .utility) { [weak self, indexBuilder] in
            let paths = await indexBuilder(roots, configuration)
            await self?.completeBuild(buildID, paths: paths, builtAt: builtAt)
        }
    }

    private func makeBuildDeadlineTask(_ buildID: UUID) -> Task<Void, Never> {
        let timeout = configuration.indexBuildTimeout
        return Task { [weak self, deadlineSleep] in
            await deadlineSleep(timeout)
            guard !Task.isCancelled else { return }
            await self?.timeoutBuild(buildID)
        }
    }

    private func cancelBuildWaiter(_ waiterID: UUID, rootIDs: Set<Data>) {
        guard let buildID = pendingBuildIDsByRoots[rootIDs],
              var build = pendingBuildsByID[buildID],
              let continuation = build.waiters.removeValue(forKey: waiterID) else { return }
        pendingBuildsByID[buildID] = build
        continuation.resume(returning: .cancelled)
    }

    private func timeoutBuild(_ buildID: UUID) {
        guard let build = pendingBuildsByID.removeValue(forKey: buildID) else { return }
        if pendingBuildIDsByRoots[build.rootIDs] == buildID {
            pendingBuildIDsByRoots.removeValue(forKey: build.rootIDs)
        }
        for continuation in build.waiters.values {
            continuation.resume(returning: .failure(.indexTimedOut))
        }
    }

    private func completeBuild(_ buildID: UUID, paths: [SearchablePath], builtAt: Date) {
        activeBuildIDs.remove(buildID)
        guard let build = pendingBuildsByID.removeValue(forKey: buildID) else { return }
        build.deadlineTask?.cancel()
        if pendingBuildIDsByRoots[build.rootIDs] == buildID {
            pendingBuildIDsByRoots.removeValue(forKey: build.rootIDs)
        }
        snapshot = Snapshot(rootIDs: build.rootIDs, paths: paths, builtAt: builtAt)
        for continuation in build.waiters.values {
            continuation.resume(returning: .success(paths))
        }
    }

    private func rankLatest(
        paths: [SearchablePath],
        query: String,
        limit: Int,
        revision: UInt64
    ) async -> [String] {
        if let prior = pendingRank {
            prior.task.cancel()
            _ = await prior.task.value
            if pendingRank?.id == prior.id { pendingRank = nil }
        }
        guard !Task.isCancelled, revision == searchRevision else { return [] }
        let rankID = UUID()
        let rankOperation = rankOperation
        let task = Task.detached(priority: .userInitiated) {
            await rankOperation(paths, query, limit)
        }
        pendingRank = PendingRank(id: rankID, task: task)
        let ranked = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if pendingRank?.id == rankID { pendingRank = nil }
        guard !Task.isCancelled, revision == searchRevision else { return [] }
        return ranked
    }

    private func foregroundMatchesLatest(
        roots: [URL],
        query: String,
        limit: Int,
        revision: UInt64
    ) async -> [String] {
        if let prior = pendingForegroundSearch {
            prior.task.cancel()
            _ = await prior.task.value
            if pendingForegroundSearch?.id == prior.id { pendingForegroundSearch = nil }
        }
        guard !roots.isEmpty, !Task.isCancelled, revision == searchRevision else { return [] }
        let searchID = UUID()
        let foregroundSearchOperation = foregroundSearchOperation
        let configuration = configuration
        let task = Task.detached(priority: .userInitiated) {
            await foregroundSearchOperation(roots, query, limit, configuration)
        }
        pendingForegroundSearch = PendingForegroundSearch(id: searchID, task: task)
        let matches = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if pendingForegroundSearch?.id == searchID { pendingForegroundSearch = nil }
        guard !Task.isCancelled, revision == searchRevision else { return [] }
        return matches
    }

    nonisolated static func rank(paths: [String], query: String, limit: Int) -> [String] {
        rank(searchablePaths: prepare(paths: paths), query: query, limit: limit)
    }

    private nonisolated static func rank(
        searchablePaths: [SearchablePath],
        query: String,
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        let foldedQuery = fold(query)
        let queryComponents = components(foldedQuery)
        let queryBasename = queryComponents.last ?? foldedQuery
        var top: [RankedPath] = []
        top.reserveCapacity(min(limit, searchablePaths.count))

        for candidate in searchablePaths {
            guard !Task.isCancelled else { return [] }
            guard let match = match(
                candidate: candidate,
                rawQuery: query,
                foldedQuery: foldedQuery,
                queryBasename: queryBasename,
                queryComponents: queryComponents
            ) else { continue }
            let ranked = RankedPath(
                candidate: candidate,
                tier: match.tier,
                unmatchedComponents: match.unmatchedComponents
            )
            let insertionIndex = top.firstIndex { isBetter(ranked, than: $0) } ?? top.endIndex
            top.insert(ranked, at: insertionIndex)
            if top.count > limit {
                top.removeLast()
            }
        }
        return top.map(\.candidate.path)
    }

    private nonisolated static func prepare(paths: [String]) -> [SearchablePath] {
        var prepared: [SearchablePath] = []
        prepared.reserveCapacity(paths.count)
        for path in paths {
            guard !Task.isCancelled else { return [] }
            let foldedPath = fold(path)
            let pathComponents = components(foldedPath)
            prepared.append(SearchablePath(
                path: path,
                pathBytes: Array(path.utf8),
                foldedPath: foldedPath,
                components: pathComponents,
                basename: pathComponents.last ?? foldedPath
            ))
        }
        return prepared
    }

    private nonisolated static func scan(
        roots: [URL],
        configuration: Configuration
    ) -> [String] {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        var queue: [(url: URL, depth: Int)] = roots.map { ($0, 0) }
        var queueIndex = 0
        var paths: [String] = []
        var seen = Set<Data>()
        var remainingFilesystemEntries = configuration.maximumFilesystemEntries

        while queueIndex < queue.count,
              paths.count < configuration.maximumDirectories,
              remainingFilesystemEntries > 0 {
            guard !Task.isCancelled else { break }
            let entry = queue[queueIndex]
            queueIndex += 1
            remainingFilesystemEntries -= 1
            guard let values = try? entry.url.resourceValues(forKeys: keys), values.isDirectory == true else {
                continue
            }
            let path = entry.url.path
            let identity = Data(path.utf8)
            guard seen.insert(identity).inserted else { continue }
            paths.append(path)

            guard entry.depth < configuration.maximumDepth,
                  values.isSymbolicLink != true,
                  values.isPackage != true,
                  !skipsDescendants(named: entry.url.lastPathComponent) else {
                continue
            }
            let queuedDirectoryCount = queue.count - queueIndex
            let availableDirectorySlots = configuration.maximumDirectories
                - paths.count
                - queuedDirectoryCount
            guard availableDirectorySlots > 0 else { continue }
            var children = boundedChildDirectories(
                at: entry.url,
                fileManager: fileManager,
                keys: keys,
                maximumDirectories: availableDirectorySlots,
                remainingFilesystemEntries: &remainingFilesystemEntries
            )
            if entry.depth == 0 {
                children.sort { rootPriority($0.lastPathComponent) < rootPriority($1.lastPathComponent) }
            }
            for child in children {
                queue.append((child, entry.depth + 1))
            }
        }
        return paths
    }

    private nonisolated static func exactForegroundMatches(
        roots: [URL],
        query: String,
        limit: Int,
        configuration: Configuration
    ) -> [String] {
        guard limit > 0,
              configuration.maximumDirectories > 0,
              configuration.maximumForegroundFilesystemEntries > 0 else { return [] }
        let foldedQuery = fold(query)
        let queryComponents = components(foldedQuery)
        let queryBasename = queryComponents.last ?? foldedQuery
        guard !queryBasename.isEmpty else { return [] }

        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        var priorityQueue: [(url: URL, depth: Int)] = []
        var regularQueue: [(url: URL, depth: Int)] = roots.map { ($0, 0) }
        var priorityIndex = 0
        var regularIndex = 0
        var seen = Set<Data>()
        var remainingFilesystemEntries = min(
            configuration.maximumFilesystemEntries,
            configuration.maximumForegroundFilesystemEntries
        )

        func nextEntry() -> (url: URL, depth: Int)? {
            if priorityIndex < priorityQueue.count {
                defer { priorityIndex += 1 }
                return priorityQueue[priorityIndex]
            }
            guard regularIndex < regularQueue.count else { return nil }
            defer { regularIndex += 1 }
            return regularQueue[regularIndex]
        }

        while let entry = nextEntry(),
              seen.count < configuration.maximumDirectories,
              remainingFilesystemEntries > 0 {
            guard !Task.isCancelled else { return [] }
            remainingFilesystemEntries -= 1
            guard let values = try? entry.url.resourceValues(forKeys: keys),
                  values.isDirectory == true else { continue }
            let path = entry.url.standardizedFileURL.path
            let identity = Data(path.utf8)
            guard seen.insert(identity).inserted else { continue }
            if exactForegroundMatch(
                path: path,
                rawQuery: query,
                foldedQuery: foldedQuery,
                queryBasename: queryBasename,
                queryComponents: queryComponents
            ) {
                return [path]
            }

            guard entry.depth < configuration.maximumDepth,
                  values.isSymbolicLink != true,
                  values.isPackage != true,
                  !skipsDescendants(named: entry.url.lastPathComponent) else { continue }
            let queuedDirectoryCount = priorityQueue.count - priorityIndex
                + regularQueue.count - regularIndex
            let availableDirectorySlots = configuration.maximumDirectories
                - seen.count
                - queuedDirectoryCount
            guard availableDirectorySlots > 0 else { continue }
            let children = boundedChildDirectories(
                at: entry.url,
                fileManager: fileManager,
                keys: keys,
                maximumDirectories: availableDirectorySlots,
                remainingFilesystemEntries: &remainingFilesystemEntries
            )
            for child in children {
                let childPath = child.standardizedFileURL.path
                if exactForegroundMatch(
                    path: childPath,
                    rawQuery: query,
                    foldedQuery: foldedQuery,
                    queryBasename: queryBasename,
                    queryComponents: queryComponents
                ) {
                    return [childPath]
                }
                if foregroundTraversalPriority(child.lastPathComponent) == 0 {
                    priorityQueue.append((child, entry.depth + 1))
                } else {
                    regularQueue.append((child, entry.depth + 1))
                }
            }
        }
        return []
    }

    private nonisolated static func exactForegroundMatch(
        path: String,
        rawQuery: String,
        foldedQuery: String,
        queryBasename: String,
        queryComponents: [String]
    ) -> Bool {
        guard let candidate = prepare(paths: [path]).first,
              candidate.foldedPath == foldedQuery || candidate.basename == queryBasename else { return false }
        return match(
            candidate: candidate,
            rawQuery: rawQuery,
            foldedQuery: foldedQuery,
            queryBasename: queryBasename,
            queryComponents: queryComponents
        ) != nil
    }

    private nonisolated static func boundedChildDirectories(
        at directory: URL,
        fileManager: FileManager,
        keys: Set<URLResourceKey>,
        maximumDirectories: Int,
        remainingFilesystemEntries: inout Int
    ) -> [URL] {
        guard maximumDirectories > 0, remainingFilesystemEntries > 0 else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var directories: [URL] = []
        directories.reserveCapacity(min(maximumDirectories, remainingFilesystemEntries))
        while directories.count < maximumDirectories, remainingFilesystemEntries > 0 {
            guard !Task.isCancelled else { break }
            guard let child = enumerator.nextObject() as? URL else { break }
            remainingFilesystemEntries -= 1
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isDirectory == true else { continue }
            directories.append(child)
        }
        return directories
    }

    private nonisolated static func searchRoots(homeDirectory: URL, seedPaths: [String]) -> [URL] {
        var roots = [homeDirectory]
        var seen = Set([Data(homeDirectory.path.utf8)])
        let homePrefix = homeDirectory.path.hasSuffix("/") ? homeDirectory.path : homeDirectory.path + "/"
        for seedPath in seedPaths {
            let trimmed = seedPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let expanded = expandHome(trimmed, homeDirectory: homeDirectory.path)
            let seedURL = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            guard seedURL.path != homeDirectory.path, !seedURL.path.hasPrefix(homePrefix) else { continue }
            let root = parentSearchRoot(for: seedURL)
            guard seen.insert(Data(root.path.utf8)).inserted else { continue }
            roots.append(root)
        }
        return roots
    }

    private nonisolated static func foregroundSearchRoots(
        homeDirectory: URL,
        seedPaths: [String]
    ) -> [URL] {
        let fileManager = FileManager.default
        var roots: [URL] = []
        var seen = Set<Data>()
        for name in ["Dev", "Developer", "Projects", "Code", "src", "Work", "Repos"] {
            let root = homeDirectory.appendingPathComponent(name, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  seen.insert(Data(root.path.utf8)).inserted else { continue }
            roots.append(root)
        }

        let homePrefix = homeDirectory.path.hasSuffix("/") ? homeDirectory.path : homeDirectory.path + "/"
        for seedPath in seedPaths {
            let trimmed = seedPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let expanded = expandHome(trimmed, homeDirectory: homeDirectory.path)
            let seedURL = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            guard seedURL.path != homeDirectory.path, !seedURL.path.hasPrefix(homePrefix) else { continue }
            let root = parentSearchRoot(for: seedURL)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  seen.insert(Data(root.path.utf8)).inserted else { continue }
            roots.append(root)
        }
        return roots
    }

    private nonisolated static func seedCandidates(
        seedPaths: [String],
        homeDirectory: URL
    ) -> [SearchablePath] {
        let fileManager = FileManager.default
        var paths: [String] = []
        var seen = Set<Data>()
        paths.reserveCapacity(seedPaths.count)

        for seedPath in seedPaths {
            guard !Task.isCancelled else { return [] }
            let trimmed = seedPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let expanded = expandHome(trimmed, homeDirectory: homeDirectory.path)
            let seedURL = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: seedURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  seen.insert(Data(seedURL.path.utf8)).inserted else { continue }
            paths.append(seedURL.path)
        }

        return prepare(paths: paths)
    }

    nonisolated static func parentSearchRoot(for seedURL: URL) -> URL {
        seedURL.path == "/" ? seedURL : seedURL.deletingLastPathComponent()
    }

    private nonisolated static func match(
        candidate: SearchablePath,
        rawQuery: String,
        foldedQuery: String,
        queryBasename: String,
        queryComponents: [String]
    ) -> (tier: Int, unmatchedComponents: Int)? {
        let unmatched = max(0, candidate.components.count - queryComponents.count)
        if candidate.pathBytes.elementsEqual(rawQuery.utf8) { return (6, 0) }
        if candidate.path.hasPrefix(rawQuery) { return (5, unmatched) }
        if candidate.foldedPath.hasPrefix(foldedQuery)
            || (queryComponents.count == 1 && candidate.basename.hasPrefix(queryBasename)) {
            return (4, unmatched)
        }
        if matchesOrderedComponentPrefixes(queryComponents, in: candidate.components) {
            return (3, unmatched)
        }
        if candidate.foldedPath.contains(foldedQuery)
            || (queryComponents.count == 1 && candidate.basename.contains(queryBasename)) {
            return (2, unmatched)
        }
        if queryComponents.count == 1, hasFuzzyComponent(queryBasename, in: candidate.components) {
            return (1, unmatched)
        }
        return nil
    }

    private nonisolated static func isBetter(_ lhs: RankedPath, than rhs: RankedPath) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
        if lhs.unmatchedComponents != rhs.unmatchedComponents {
            return lhs.unmatchedComponents < rhs.unmatchedComponents
        }
        let lhsBytes = lhs.candidate.pathBytes
        let rhsBytes = rhs.candidate.pathBytes
        if lhsBytes.count != rhsBytes.count { return lhsBytes.count < rhsBytes.count }
        return lhsBytes.lexicographicallyPrecedes(rhsBytes)
    }

    private nonisolated static func fold(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private nonisolated static func components(_ value: String) -> [String] {
        value.split { $0 == "/" || $0.isWhitespace }.map(String.init)
    }

    private nonisolated static func matchesOrderedComponentPrefixes(
        _ query: [String],
        in candidate: [String]
    ) -> Bool {
        guard !query.isEmpty else { return false }
        var candidateIndex = candidate.startIndex
        for queryComponent in query {
            guard let match = candidate[candidateIndex...].firstIndex(where: { $0.hasPrefix(queryComponent) }) else {
                return false
            }
            candidateIndex = candidate.index(after: match)
        }
        return true
    }

    private nonisolated static func expandHome(_ path: String, homeDirectory: String) -> String {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") { return homeDirectory + path.dropFirst() }
        return path
    }

    private nonisolated static func skipsDescendants(named name: String) -> Bool {
        switch name.lowercased() {
        case "library", "node_modules", "deriveddata", "pods", ".build", ".git", ".trash", "caches":
            true
        default:
            false
        }
    }

    private nonisolated static func rootPriority(_ name: String) -> Int {
        switch name.lowercased() {
        case "dev", "developer", "projects", "code", "src", "work", "repos": 0
        case "desktop", "documents", "downloads": 1
        default: 2
        }
    }

    private nonisolated static func foregroundTraversalPriority(_ name: String) -> Int {
        switch name.lowercased() {
        case "worktrees", "projects", "repos": 0
        default: 1
        }
    }
}
