public import CmuxFoundation
import Foundation

/// Lists and ranks files for the Go to File palette mode.
public struct GoToFileSearchService: Sendable {
    private let maximumResults: Int
    private let commandRunner: any CommandRunning
    private let ripgrepExecutable: String?
    private let ripgrepPrefixArguments: [String]

    /// Creates a search service with injected subprocess and ripgrep resolution.
    public init(
        maximumResults: Int = 200,
        commandRunner: any CommandRunning = CommandRunner(),
        ripgrepExecutable: String? = nil,
        ripgrepPrefixArguments: [String] = []
    ) {
        self.maximumResults = max(1, maximumResults)
        self.commandRunner = commandRunner
        self.ripgrepExecutable = ripgrepExecutable
        self.ripgrepPrefixArguments = ripgrepPrefixArguments
    }

    /// Lists and ranks files under `rootPath` using one workspace snapshot.
    public func search(rootPath: String, query: String) async -> [GoToFileMatch] {
        await search(paths: snapshot(rootPath: rootPath), query: query)
    }

    /// Lists tracked and non-ignored files under `rootPath`.
    public func snapshot(rootPath: String) async -> [String] {
        let git = await commandRunner.run(
            directory: rootPath,
            executable: "/usr/bin/git",
            arguments: ["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "."],
            timeout: 30
        )
        if git.executionError == nil, !git.timedOut, git.exitStatus == 0,
           let stdout = git.stdout {
            return Self.parseNullSeparated(Data(stdout.utf8))
        }

        guard let ripgrepExecutable else { return [] }
        let rg = await commandRunner.run(
            directory: rootPath,
            executable: ripgrepExecutable,
            arguments: ripgrepPrefixArguments + ["--files", "--hidden", "--null", "--glob", "!.git"],
            timeout: 30
        )
        guard rg.executionError == nil, !rg.timedOut, rg.exitStatus == 0,
              let stdout = rg.stdout else { return [] }
        return Self.parseNullSeparated(Data(stdout.utf8))
    }

    /// Ranks a previously enumerated snapshot without touching the filesystem.
    public func search(paths: [String], query: String) async -> [GoToFileMatch] {
        let maximumResults = maximumResults
        let worker = Task.detached(priority: .userInitiated) {
            Self.rank(paths: paths, query: query, limit: maximumResults, shouldCancel: { Task.isCancelled })
                .map(GoToFileMatch.init(path:))
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func rank(paths: [String], query: String, limit: Int) -> [String] {
        rank(paths: paths, query: query, limit: limit, shouldCancel: { false })
    }

    private static func rank(
        paths: [String],
        query: String,
        limit: Int,
        shouldCancel: () -> Bool
    ) -> [String] {
        guard limit > 0 else { return [] }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            var best: [String] = []
            best.reserveCapacity(min(limit, paths.count))
            for (index, path) in paths.enumerated() {
                if index.isMultiple(of: 16), shouldCancel() { return [] }
                insertBounded(path, into: &best, limit: limit) {
                    $0.localizedStandardCompare($1) == .orderedAscending
                }
            }
            return best.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
        }
        let matcher = CommandPaletteFuzzyMatcher(query: trimmedQuery)
        var best: [(String, Int)] = []
        best.reserveCapacity(min(limit, paths.count))
        for (index, path) in paths.enumerated() {
            if index.isMultiple(of: 16), shouldCancel() { return [] }
            guard let score = matcher.score(candidate: path) else { continue }
            insertBounded((path, score), into: &best, limit: limit) {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.localizedStandardCompare($1.0) == .orderedAscending
            }
        }
        return best.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.localizedStandardCompare($1.0) == .orderedAscending
        }.map(\.0)
    }

    private static func parseNullSeparated(_ data: Data) -> [String] {
        data.split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
    }

    private static func insertBounded<Element>(
        _ element: Element,
        into best: inout [Element],
        limit: Int,
        by isBetter: (Element, Element) -> Bool
    ) {
        guard limit > 0 else { return }
        guard best.count < limit else {
            var worstIndex = best.startIndex
            for index in best.indices.dropFirst() where isBetter(best[worstIndex], best[index]) { worstIndex = index }
            guard isBetter(element, best[worstIndex]) else { return }
            best[worstIndex] = element
            return
        }
        best.append(element)
    }
}
