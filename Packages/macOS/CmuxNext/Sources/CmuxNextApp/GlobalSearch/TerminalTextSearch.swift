import CmuxNextDaemon
import Foundation

/// Search All Windows over terminal text: every terminal tab on every
/// machine, read from its daemon (retained history and the screen), so tabs
/// no window shows are searched too. A line matches when it contains every
/// word of the query, ignoring case, as the old app's search matched words.
nonisolated enum TerminalTextSearch {
    /// One terminal to read.
    nonisolated struct Target: Sendable {
        let tabID: String
        let surface: SurfaceID
        let connection: DaemonConnection
    }

    /// History rows read per terminal (the old app captured 4,000).
    static let historyRows: UInt32 = 4_000
    /// Matches shown in all.
    static let limit = 200
    /// Matches shown per terminal, so one noisy log cannot fill the page.
    static let perTerminal = 20
    /// Per request; a busy or unreachable daemon's terminals count as unread.
    static let timeout: Duration = .seconds(2)
    /// Terminals read at once, so a search does not flood the connections
    /// that also carry typing and output.
    static let concurrentReads = 8

    nonisolated struct Results: Sendable {
        var matches: [(tabID: String, lines: [String])] = []
        var limited = false
        /// Terminals whose text could not be read.
        var unreadable = 0
    }

    static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The newest lines containing every word, newest first, each once.
    static func matches(in lines: [String], words: [String], limit: Int = perTerminal) -> [String] {
        guard !words.isEmpty else { return [] }
        var found: [String] = []
        var seen = Set<String>()
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            let lowered = trimmed.lowercased()
            guard words.allSatisfy({ lowered.contains($0) }) else { continue }
            seen.insert(trimmed)
            found.append(trimmed)
            if found.count == limit { break }
        }
        return found
    }

    /// Matches per target, in target order, at most `limit` in all.
    /// `read` gives a terminal's lines, oldest first, or nil when it could
    /// not be read.
    @concurrent static func search(
        _ targets: [Target], words: [String], limit: Int = limit,
        read: @escaping @Sendable (Target) async -> [String]? = lines(of:)
    ) async -> Results {
        let found = await withTaskGroup(of: (Int, [String]?).self) { group in
            var found = [[String]?](repeating: nil, count: targets.count)
            var queue = targets.enumerated().makeIterator()
            for _ in 0..<concurrentReads {
                guard let next = queue.next() else { break }
                group.addTask { (next.offset, await read(next.element).map { matches(in: $0, words: words) }) }
            }
            for await (index, lines) in group {
                found[index] = lines
                // A dismissed palette cancels the search: stop queueing reads.
                if !Task.isCancelled, let next = queue.next() {
                    group.addTask { (next.offset, await read(next.element).map { matches(in: $0, words: words) }) }
                }
            }
            return found
        }
        var results = Results(unreadable: found.count(where: { $0 == nil }))
        var remaining = limit
        for (target, lines) in zip(targets, found) {
            guard let lines, !lines.isEmpty else { continue }
            guard remaining > 0 else {
                results.limited = true
                break
            }
            if lines.count > remaining { results.limited = true }
            results.matches.append((target.tabID, Array(lines.prefix(remaining))))
            remaining -= min(lines.count, remaining)
        }
        return results
    }

    /// The last `historyRows` history rows, then the screen; nil when the
    /// daemon did not answer.
    static func lines(of target: Target) async -> [String]? {
        let connection = target.connection, surface = target.surface
        var lines: [String] = []
        if let total = try? await connection.request(ReadScrollbackRequest(surface: surface, start: 0, count: 0), timeout: timeout).total,
           total > 0 {
            let count = min(total, historyRows)
            let page = try? await connection.request(ReadScrollbackRequest(surface: surface, start: total - count, count: count),
                                                     timeout: timeout)
            lines = page?.lines ?? []
        }
        guard let screen = try? await connection.request(ReadScreenRequest(surface: surface), timeout: timeout) else { return nil }
        return lines + screen.text.components(separatedBy: "\n")
    }
}
