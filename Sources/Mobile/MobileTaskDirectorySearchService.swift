import Foundation

/// Searches Spotlight metadata across all indexed mounted volumes, merges
/// contextual cmux paths, and reports the remaining coverage limits explicitly.
actor MobileTaskDirectorySearchService {
    struct Configuration: Sendable {
        var maximumMetadataResults = 2_048
        var maximumWireResults = 64
        var queryTimeout: Duration = .seconds(2)
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

    typealias MetadataSearchOperation = @MainActor @Sendable (
        _ query: String,
        _ maximumResults: Int,
        _ timeout: Duration
    ) async throws -> MobileTaskDirectoryMetadataQueryRunner.Snapshot
    typealias RankOperation = @Sendable (
        _ paths: [SearchablePath],
        _ query: String,
        _ limit: Int
    ) async -> [String]
    typealias DirectoryExists = @Sendable (_ path: String) -> Bool

    private let homeDirectory: URL
    private let configuration: Configuration
    private let metadataSearchOperation: MetadataSearchOperation
    private let rankOperation: RankOperation
    private let directoryExists: DirectoryExists

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        configuration: Configuration = Configuration(),
        metadataSearchOperation: MetadataSearchOperation? = nil,
        rankOperation: RankOperation? = nil,
        directoryExists: DirectoryExists? = nil
    ) {
        precondition(configuration.maximumMetadataResults > 0)
        precondition(configuration.maximumWireResults > 0)
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.configuration = configuration
        self.metadataSearchOperation = metadataSearchOperation ?? { query, maximumResults, timeout in
            try await MobileTaskDirectoryMetadataQueryRunner().search(
                query: query,
                maximumResults: maximumResults,
                timeout: timeout
            )
        }
        self.rankOperation = rankOperation ?? { paths, query, limit in
            await Task.detached(priority: .userInitiated) {
                Self.rank(searchablePaths: paths, query: query, limit: limit)
            }.value
        }
        self.directoryExists = directoryExists ?? { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    func search(
        query rawQuery: String,
        seedPaths: [String],
        limit: Int = 64
    ) async throws -> MobileTaskDirectorySearchResult {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else {
            return MobileTaskDirectorySearchResult(
                directories: [],
                scope: .contextualCandidatesOnly,
                gatheringComplete: false,
                filesystemComplete: false,
                truncated: false,
                indexedMatchCount: 0
            )
        }
        let expandedQuery = Self.expandHome(query, homeDirectory: homeDirectory.path)
        let maximumResults = min(limit, configuration.maximumWireResults, 64)
        let contextualPaths = Self.seedCandidates(
            seedPaths: seedPaths,
            homeDirectory: homeDirectory,
            directoryExists: directoryExists
        )

        guard !Task.isCancelled else {
            throw CancellationError()
        }

        let metadataSearchOperation = metadataSearchOperation
        let maximumMetadataResults = configuration.maximumMetadataResults
        let queryTimeout = configuration.queryTimeout
        let metadataTask = Task { @MainActor in
            try await metadataSearchOperation(expandedQuery, maximumMetadataResults, queryTimeout)
        }

        let metadataSnapshot: MobileTaskDirectoryMetadataQueryRunner.Snapshot
        do {
            metadataSnapshot = try await withTaskCancellationHandler {
                try await metadataTask.value
            } onCancel: {
                metadataTask.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch MobileTaskDirectoryMetadataQueryRunner.QueryError.unavailable {
            return try await contextualResult(
                paths: contextualPaths,
                query: expandedQuery,
                maximumResults: maximumResults
            )
        } catch {
            return try await contextualResult(
                paths: contextualPaths,
                query: expandedQuery,
                maximumResults: maximumResults
            )
        }
        guard !Task.isCancelled else {
            throw CancellationError()
        }

        let metadataPaths = Self.prepare(paths: metadataSnapshot.paths)
        let merged = Self.unique(contextualPaths + metadataPaths)
        let ranked = await rankOperation(merged, expandedQuery, merged.count)
        guard !Task.isCancelled else {
            throw CancellationError()
        }
        return MobileTaskDirectorySearchResult(
            directories: Array(ranked.prefix(maximumResults)),
            scope: .allIndexedVolumes,
            gatheringComplete: metadataSnapshot.gatheringComplete,
            filesystemComplete: false,
            truncated: metadataSnapshot.truncated || ranked.count > maximumResults,
            indexedMatchCount: metadataSnapshot.totalMatchCount
        )
    }

    private func contextualResult(
        paths: [SearchablePath],
        query: String,
        maximumResults: Int
    ) async throws -> MobileTaskDirectorySearchResult {
        let ranked = await rankOperation(paths, query, paths.count)
        guard !Task.isCancelled else {
            throw CancellationError()
        }
        return MobileTaskDirectorySearchResult(
            directories: Array(ranked.prefix(maximumResults)),
            scope: .contextualCandidatesOnly,
            gatheringComplete: false,
            filesystemComplete: false,
            truncated: ranked.count > maximumResults,
            indexedMatchCount: 0
        )
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

    private nonisolated static func unique(_ paths: [SearchablePath]) -> [SearchablePath] {
        var seen = Set<Data>()
        return paths.filter { seen.insert(Data($0.pathBytes)).inserted }
    }

    private nonisolated static func seedCandidates(
        seedPaths: [String],
        homeDirectory: URL,
        directoryExists: DirectoryExists
    ) -> [SearchablePath] {
        var paths: [String] = []
        var seen = Set<Data>()
        paths.reserveCapacity(seedPaths.count)

        for seedPath in seedPaths {
            guard !Task.isCancelled else { return [] }
            let trimmed = seedPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let expanded = expandHome(trimmed, homeDirectory: homeDirectory.path)
            let path = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
            guard directoryExists(path), seen.insert(Data(path.utf8)).inserted else { continue }
            paths.append(path)
        }
        return prepare(paths: paths)
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
            guard let match = candidate[candidateIndex...].firstIndex(where: {
                $0.hasPrefix(queryComponent)
            }) else {
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
}
