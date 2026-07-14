import Foundation

/// Builds a bounded, short-lived directory index on the Mac and searches it
/// without exposing filesystem traversal to the phone. The index stays warm
/// across keystrokes, never follows symlinks, and skips dependency/cache trees
/// that are both noisy and expensive to enumerate.
actor MobileTaskDirectorySearchService {
    struct Configuration: Sendable {
        var maximumDirectories = 12_000
        var maximumDepth = 6
        var cacheLifetime: TimeInterval = 30
    }

    static let shared = MobileTaskDirectorySearchService()

    private struct Snapshot: Sendable {
        let rootIDs: Set<Data>
        let paths: [String]
        let builtAt: Date
    }

    private struct PendingBuild: Sendable {
        let id: UUID
        let rootIDs: Set<Data>
        let task: Task<[String], Never>
    }

    private struct RankedPath {
        let path: String
        let tier: Int
        let unmatchedComponents: Int
    }

    private let homeDirectory: URL
    private let configuration: Configuration
    private var snapshot: Snapshot?
    private var pendingBuild: PendingBuild?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        configuration: Configuration = Configuration()
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.configuration = configuration
    }

    func search(
        query rawQuery: String,
        seedPaths: [String],
        limit: Int = 64,
        now: Date = Date()
    ) async -> [String] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        let roots = Self.searchRoots(homeDirectory: homeDirectory, seedPaths: seedPaths)
        let paths = await indexedPaths(roots: roots, now: now)
        let expandedQuery = Self.expandHome(query, homeDirectory: homeDirectory.path)
        return Self.rank(paths: paths, query: expandedQuery, limit: min(limit, 64))
    }

    private func indexedPaths(roots: [URL], now: Date) async -> [String] {
        let rootIDs = Set(roots.map { Data($0.path.utf8) })
        if let snapshot,
           now.timeIntervalSince(snapshot.builtAt) < configuration.cacheLifetime,
           rootIDs.isSubset(of: snapshot.rootIDs) {
            return snapshot.paths
        }
        if let pendingBuild, rootIDs == pendingBuild.rootIDs {
            return await pendingBuild.task.value
        }

        let id = UUID()
        let configuration = configuration
        let task = Task.detached(priority: .utility) {
            Self.scan(roots: roots, configuration: configuration)
        }
        pendingBuild = PendingBuild(id: id, rootIDs: rootIDs, task: task)
        let paths = await task.value
        if pendingBuild?.id == id {
            snapshot = Snapshot(rootIDs: rootIDs, paths: paths, builtAt: now)
            pendingBuild = nil
        }
        return paths
    }

    nonisolated static func rank(paths: [String], query: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let foldedQuery = fold(query)
        let queryComponents = components(foldedQuery)
        let queryBasename = queryComponents.last ?? foldedQuery
        var top: [RankedPath] = []
        top.reserveCapacity(min(limit, paths.count))

        for path in paths {
            guard let match = match(
                path: path,
                rawQuery: query,
                foldedQuery: foldedQuery,
                queryBasename: queryBasename,
                queryComponents: queryComponents
            ) else { continue }
            let ranked = RankedPath(
                path: path,
                tier: match.tier,
                unmatchedComponents: match.unmatchedComponents
            )
            let insertionIndex = top.firstIndex { isBetter(ranked, than: $0) } ?? top.endIndex
            top.insert(ranked, at: insertionIndex)
            if top.count > limit {
                top.removeLast()
            }
        }
        return top.map(\.path)
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

        while queueIndex < queue.count, paths.count < configuration.maximumDirectories {
            guard !Task.isCancelled else { break }
            let entry = queue[queueIndex]
            queueIndex += 1
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
            guard var children = try? fileManager.contentsOfDirectory(
                at: entry.url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { continue }
            if entry.depth == 0 {
                children.sort { rootPriority($0.lastPathComponent) < rootPriority($1.lastPathComponent) }
            }
            for child in children where paths.count + queue.count - queueIndex < configuration.maximumDirectories {
                guard let childValues = try? child.resourceValues(forKeys: keys),
                      childValues.isDirectory == true else { continue }
                queue.append((child, entry.depth + 1))
            }
        }
        return paths
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
            let root = seedURL.deletingLastPathComponent()
            guard seen.insert(Data(root.path.utf8)).inserted else { continue }
            roots.append(root)
        }
        return roots
    }

    private nonisolated static func match(
        path: String,
        rawQuery: String,
        foldedQuery: String,
        queryBasename: String,
        queryComponents: [String]
    ) -> (tier: Int, unmatchedComponents: Int)? {
        let foldedPath = fold(path)
        let pathComponents = components(foldedPath)
        let basename = pathComponents.last ?? foldedPath
        let unmatched = max(0, pathComponents.count - queryComponents.count)
        if Data(path.utf8) == Data(rawQuery.utf8) { return (6, 0) }
        if path.hasPrefix(rawQuery) { return (5, unmatched) }
        if foldedPath.hasPrefix(foldedQuery)
            || (queryComponents.count == 1 && basename.hasPrefix(queryBasename)) {
            return (4, unmatched)
        }
        if matchesOrderedComponentPrefixes(queryComponents, in: pathComponents) {
            return (3, unmatched)
        }
        if foldedPath.contains(foldedQuery)
            || (queryComponents.count == 1 && basename.contains(queryBasename)) {
            return (2, unmatched)
        }
        if queryComponents.count == 1, hasFuzzyComponent(queryBasename, in: pathComponents) {
            return (1, unmatched)
        }
        return nil
    }

    private nonisolated static func isBetter(_ lhs: RankedPath, than rhs: RankedPath) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
        if lhs.unmatchedComponents != rhs.unmatchedComponents {
            return lhs.unmatchedComponents < rhs.unmatchedComponents
        }
        let lhsBytes = Array(lhs.path.utf8)
        let rhsBytes = Array(rhs.path.utf8)
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

    private nonisolated static func hasFuzzyComponent(_ query: String, in components: [String]) -> Bool {
        guard query.count >= 3 else { return false }
        let maximum = query.count >= 7 ? 2 : 1
        return components.contains { component in
            abs(component.count - query.count) <= maximum
                && editDistance(component, query, maximum: maximum) <= maximum
        }
    }

    private nonisolated static func editDistance(_ lhs: String, _ rhs: String, maximum: Int) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard abs(left.count - right.count) <= maximum else { return maximum + 1 }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(right.count + 1)
            var rowMinimum = current[0]
            for (rightIndex, rightCharacter) in right.enumerated() {
                let value = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
                current.append(value)
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > maximum { return maximum + 1 }
            previous = current
        }
        return previous.last ?? maximum + 1
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
}
