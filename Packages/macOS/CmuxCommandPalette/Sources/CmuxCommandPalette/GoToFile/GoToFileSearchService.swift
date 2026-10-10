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
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    public nonisolated func search(rootPath: String, query: String) async -> [GoToFileMatch] {
        await search(paths: snapshot(rootPath: rootPath), query: query)
    }

    /// Lists tracked and non-ignored files under `rootPath`.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    public nonisolated func snapshot(rootPath: String) async -> [String] {
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
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    public nonisolated func search(paths: [String], query: String) async -> [GoToFileMatch] {
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
            var best = WorstFirstHeap<String>(isBetter: {
                $0.localizedStandardCompare($1) == .orderedAscending
            })
            for (index, path) in paths.enumerated() {
                if index.isMultiple(of: 16), shouldCancel() { return [] }
                best.insert(path, limit: limit)
            }
            return best.elements.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
        }
        let matcher = CommandPaletteFuzzyMatcher(query: trimmedQuery)
        var best = WorstFirstHeap<(String, Int)>(isBetter: {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.localizedStandardCompare($1.0) == .orderedAscending
        })
        for (index, path) in paths.enumerated() {
            if index.isMultiple(of: 16), shouldCancel() { return [] }
            guard let score = matcher.score(candidate: path) else { continue }
            best.insert((path, score), limit: limit)
        }
        return best.elements.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.localizedStandardCompare($1.0) == .orderedAscending
        }.map(\.0)
    }

    private static func parseNullSeparated(_ data: Data) -> [String] {
        data.split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
    }

    private struct WorstFirstHeap<Element> {
        private(set) var elements: [Element] = []
        private let isBetter: (Element, Element) -> Bool

        init(isBetter: @escaping (Element, Element) -> Bool) {
            self.isBetter = isBetter
        }

        mutating func insert(_ element: Element, limit: Int) {
            guard limit > 0 else { return }
            if elements.count < limit {
                elements.append(element)
                siftUp(from: elements.index(before: elements.endIndex))
                return
            }
            guard let worst = elements.first, isBetter(element, worst) else { return }
            elements[0] = element
            siftDown(from: 0)
        }

        private func isWorse(_ lhs: Element, than rhs: Element) -> Bool {
            isBetter(rhs, lhs)
        }

        private mutating func siftUp(from start: Int) {
            var child = start
            while child > 0 {
                let parent = (child - 1) / 2
                guard isWorse(elements[child], than: elements[parent]) else { return }
                elements.swapAt(child, parent)
                child = parent
            }
        }

        private mutating func siftDown(from start: Int) {
            var parent = start
            while true {
                let left = parent * 2 + 1
                guard left < elements.count else { return }
                var worstChild = left
                let right = left + 1
                if right < elements.count, isWorse(elements[right], than: elements[left]) {
                    worstChild = right
                }
                guard isWorse(elements[worstChild], than: elements[parent]) else { return }
                elements.swapAt(parent, worstChild)
                parent = worstChild
            }
        }
    }
}
