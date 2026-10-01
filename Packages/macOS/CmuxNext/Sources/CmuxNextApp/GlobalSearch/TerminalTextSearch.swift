import CmuxNextDaemon
import Foundation

/// Search All Windows over terminal text: every terminal tab on every
/// machine, read from its daemon (retained history and the screen), so tabs
/// no window shows are searched too. A line matches when it contains every
/// word of the query, ignoring case, as the old app's search matched words.
nonisolated enum TerminalTextSearch {
    /// One terminal to read.
    struct Target: Sendable {
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
    /// Per request; a busy or unreachable daemon drops its terminals.
    static let timeout: Duration = .seconds(2)

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
    /// `read` gives a terminal's lines, oldest first.
    @concurrent static func search(
        _ targets: [Target], words: [String], limit: Int = limit,
        read: @escaping @Sendable (Target) async -> [String] = lines(of:)
    ) async -> (matches: [(tabID: String, lines: [String])], limited: Bool) {
        let found = await withTaskGroup(of: (Int, [String]).self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask { (index, matches(in: await read(target), words: words)) }
            }
            var found = [[String]](repeating: [], count: targets.count)
            for await (index, lines) in group { found[index] = lines }
            return found
        }
        var remaining = limit
        var result: [(tabID: String, lines: [String])] = []
        var limited = false
        for (target, lines) in zip(targets, found) where !lines.isEmpty {
            guard remaining > 0 else {
                limited = true
                break
            }
            if lines.count > remaining { limited = true }
            result.append((target.tabID, Array(lines.prefix(remaining))))
            remaining -= min(lines.count, remaining)
        }
        return (result, limited)
    }

    /// The last `historyRows` history rows, then the screen.
    static func lines(of target: Target) async -> [String] {
        let connection = target.connection, surface = target.surface
        var lines: [String] = []
        if let total = try? await connection.request(ReadScrollbackRequest(surface: surface, start: 0, count: 0), timeout: timeout).total,
           total > 0 {
            let count = min(total, historyRows)
            let page = try? await connection.request(ReadScrollbackRequest(surface: surface, start: total - count, count: count),
                                                     timeout: timeout)
            lines = page?.lines ?? []
        }
        if let screen = try? await connection.request(ReadScreenRequest(surface: surface), timeout: timeout) {
            lines += screen.text.components(separatedBy: "\n")
        }
        return lines
    }
}
