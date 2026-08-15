import Foundation

/// Parsed Vault session search input: free text plus prefix operators
/// (`agent:`, `repo:`, `ws:`, `before:`, `after:`). Pure value — parsing and
/// matching never touch the filesystem.
struct VaultSessionSearchQuery: Equatable, Sendable {
    /// Free-text terms (lowercased). Quoted phrases stay one term.
    var textTerms: [String] = []
    /// `agent:` operator values (lowercased). Multiple values OR together.
    var agentTerms: [String] = []
    /// `repo:` operator values (lowercased substring of the cwd basename).
    var repoTerms: [String] = []
    /// `ws:` operator values (lowercased substring of the full cwd).
    var workspaceTerms: [String] = []
    /// `modified` must be >= this instant (start of the `after:` day).
    var after: Date?
    /// `modified` must be < this instant (start of the `before:` day).
    var before: Date?

    var isEmpty: Bool {
        textTerms.isEmpty && agentTerms.isEmpty && repoTerms.isEmpty
            && workspaceTerms.isEmpty && after == nil && before == nil
    }

    /// Free text re-joined for handing to the existing per-agent transcript
    /// search paths (which take a single needle).
    var residualText: String {
        textTerms.joined(separator: " ")
    }

    // MARK: Parsing

    nonisolated static func parse(_ raw: String, calendar: Calendar = .current) -> VaultSessionSearchQuery {
        var query = VaultSessionSearchQuery()
        for token in tokenize(raw) {
            if let (op, value) = splitOperator(token) {
                let lowered = value.lowercased()
                switch op {
                case "agent":
                    if !lowered.isEmpty { query.agentTerms.append(lowered) }
                    continue
                case "repo":
                    if !lowered.isEmpty { query.repoTerms.append(lowered) }
                    continue
                case "ws":
                    if !lowered.isEmpty { query.workspaceTerms.append(lowered) }
                    continue
                case "before":
                    if let day = parseDay(value, calendar: calendar) {
                        query.before = day
                        continue
                    }
                case "after":
                    if let day = parseDay(value, calendar: calendar) {
                        query.after = day
                        continue
                    }
                default:
                    break
                }
            }
            let lowered = token.lowercased()
            if !lowered.isEmpty { query.textTerms.append(lowered) }
        }
        return query
    }

    /// Split into whitespace-separated tokens, keeping double-quoted phrases
    /// together (quotes stripped). An operator value may be quoted too
    /// (`repo:"my project"`).
    nonisolated private static func tokenize(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for char in raw {
            if char == "\"" {
                inQuotes.toggle()
                continue
            }
            if char.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(current) }
                current = ""
                continue
            }
            current.append(char)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    nonisolated private static func splitOperator(_ token: String) -> (String, String)? {
        guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else { return nil }
        let op = String(token[..<colon]).lowercased()
        guard ["agent", "repo", "ws", "before", "after"].contains(op) else { return nil }
        return (op, String(token[token.index(after: colon)...]))
    }

    /// Strict `yyyy-MM-dd`; returns the start of that day in `calendar`.
    nonisolated private static func parseDay(_ value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        return calendar.startOfDay(for: date)
    }

    // MARK: Matching

    /// Operator constraints only (no free text). Used for results whose text
    /// match happened inside the transcript rather than the metadata.
    nonisolated func matchesOperators(_ entry: SessionEntry) -> Bool {
        if !agentTerms.isEmpty {
            let rawValue = entry.agent.rawValue.lowercased()
            let display = entry.agent.displayName.lowercased()
            guard agentTerms.contains(where: { rawValue.contains($0) || display.contains($0) }) else {
                return false
            }
        }
        if !repoTerms.isEmpty {
            let basename = (entry.cwdBasename ?? "").lowercased()
            guard repoTerms.allSatisfy({ basename.contains($0) }) else { return false }
        }
        if !workspaceTerms.isEmpty {
            let cwd = (entry.cwd ?? "").lowercased()
            guard workspaceTerms.allSatisfy({ cwd.contains($0) }) else { return false }
        }
        if let after, entry.modified < after { return false }
        if let before, entry.modified >= before { return false }
        return true
    }

    /// Full metadata match: operators plus every free-text term appearing in
    /// the title, cwd, branch, or agent name.
    nonisolated func matchesMetadata(_ entry: SessionEntry) -> Bool {
        guard matchesOperators(entry) else { return false }
        guard !textTerms.isEmpty else { return true }
        let haystack = [
            entry.displayTitle,
            entry.cwd ?? "",
            entry.gitBranch ?? "",
            entry.agent.displayName,
            entry.agent.rawValue,
        ].joined(separator: "\n").lowercased()
        return textTerms.allSatisfy { haystack.contains($0) }
    }

    /// True when every free-text term appears in the entry title. Used as the
    /// ranking tie-break (title hits outrank transcript-only hits).
    nonisolated func matchesTitle(_ entry: SessionEntry) -> Bool {
        guard !textTerms.isEmpty else { return false }
        let title = entry.displayTitle.lowercased()
        return textTerms.allSatisfy { title.contains($0) }
    }
}

/// Recency-first ranking for merged session search results.
enum VaultSessionSearchRanking {
    /// Dedupes by `SessionEntry.id` (first occurrence wins) and sorts:
    /// newest `modified` first; ties prefer title matches; final tie-break on
    /// the stable entry id so ordering is deterministic.
    nonisolated static func rank(
        _ entries: [SessionEntry],
        query: VaultSessionSearchQuery
    ) -> [SessionEntry] {
        var seen: Set<String> = []
        var deduped: [SessionEntry] = []
        deduped.reserveCapacity(entries.count)
        for entry in entries where seen.insert(entry.id).inserted {
            deduped.append(entry)
        }
        return deduped.sorted { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            let lhsTitle = query.matchesTitle(lhs)
            let rhsTitle = query.matchesTitle(rhs)
            if lhsTitle != rhsTitle { return lhsTitle }
            return lhs.id < rhs.id
        }
    }
}
