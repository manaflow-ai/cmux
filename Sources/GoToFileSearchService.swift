import CmuxCommandPalette
import Foundation

/// A workspace file returned by Go to File.
struct GoToFileMatch: Identifiable, Equatable, Sendable {
    let path: String

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
}

/// Lists and ranks files for the Go to File palette mode.
struct GoToFileSearchService: Sendable {
    let maximumResults: Int

    init(maximumResults: Int = 200) {
        self.maximumResults = max(1, maximumResults)
    }

    func search(rootPath: String, query: String) async -> [GoToFileMatch] {
        let maximumResults = maximumResults
        return await Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return [] }
            let paths = Self.listedPaths(rootPath: rootPath)
            guard !Task.isCancelled else { return [] }
            return Self.rank(paths: paths, query: query, limit: maximumResults)
                .map(GoToFileMatch.init(path:))
        }.value
    }

    /// The first command uses git's exclude-standard implementation, which
    /// includes tracked files and untracked files that are not ignored.
    /// Non-repository workspaces fall back to ripgrep, which applies the same
    /// gitignore rules while walking the directory.
    static func listedPaths(rootPath: String) -> [String] {
        let git = run(
            executable: "/usr/bin/git",
            arguments: ["-C", rootPath, "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
        )
        if git.status == 0 {
            return parseNullSeparated(git.output)
        }
        let rg = run(
            executable: "/usr/bin/env",
            arguments: ["rg", "--files", "--hidden", "--glob", "!.git", rootPath]
        )
        guard rg.status == 0 else { return [] }
        return rg.output.split(whereSeparator: { $0 == 10 || $0 == 13 }).compactMap {
            String(data: Data($0), encoding: .utf8)
        }.map { path in
                let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
                return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            }
    }

    static func rank(paths: [String], query: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return Array(paths.sorted().prefix(limit)) }
        let matcher = CommandPaletteFuzzyMatcher(query: trimmedQuery)
        return paths
            .compactMap { path -> (String, Int)? in
                guard let score = matcher.score(candidate: path) else { return nil }
                return (path, score)
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.localizedStandardCompare($1.0) == .orderedAscending
            }
            .prefix(limit)
            .map(\.0)
    }

    private static func parseNullSeparated(_ data: Data) -> [String] {
        data.split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
    }

    private static func run(executable: String, arguments: [String]) -> (output: Data, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return (pipe.fileHandleForReading.readDataToEndOfFile(), process.terminationStatus)
        } catch {
            return (Data(), -1)
        }
    }
}
