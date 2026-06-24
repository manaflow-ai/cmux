public import Foundation
import CmuxFoundation

/// One deduplicated Antigravity history conversation resolved from an agent's
/// `history.jsonl` rollouts: its native session id, display title, optional
/// working directory, latest modification date, and the `history.jsonl` file it
/// was read from.
///
/// Antigravity records every conversation as a line in a per-root `history.jsonl`,
/// and a single conversation can appear in multiple lines/roots; the resolver
/// collapses each `sessionId` to its most recently modified record and yields one
/// entry. Package-owned `Sendable` value type so the resolver never constructs an
/// app-side `SessionEntry`; the app loader maps these fields onto a `SessionEntry`
/// plus its `CmuxVaultAgentRegistration` specifics.
public struct AntigravityHistoryEntry: Sendable, Hashable {
    /// The conversation's native Antigravity session id.
    public let sessionId: String
    /// The conversation's display title (empty when the record carries none).
    public let title: String
    /// The conversation's working directory, when the record supplies one.
    public let cwd: String?
    /// The most recent modification date across the records for this session id.
    public let modified: Date
    /// The `history.jsonl` file the winning record was read from.
    public let fileURL: URL

    /// Creates a history entry.
    ///
    /// - Parameters:
    ///   - sessionId: The native Antigravity session id.
    ///   - title: The display title (empty string when none).
    ///   - cwd: The working directory, if known.
    ///   - modified: The latest modification date for this session id.
    ///   - fileURL: The `history.jsonl` file the record came from.
    public init(
        sessionId: String,
        title: String,
        cwd: String?,
        modified: Date,
        fileURL: URL
    ) {
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.modified = modified
        self.fileURL = fileURL
    }
}

extension RegisteredAgentSessionResolver {
    /// Resolves the deduplicated, ordered Antigravity history conversations for a
    /// registered agent, given its configured session directory and an optional cwd
    /// filter and search needle.
    ///
    /// Scans each `history.jsonl` under the agent's session roots line by line,
    /// matching records against the needle (and `cwdFilter`), then collapses every
    /// `sessionId` to its most recently modified record. The result is ordered
    /// newest-first, breaking ties by ascending `sessionId`. Honors task
    /// cancellation. The app loader applies offset/limit windowing and maps each
    /// entry onto a `SessionEntry`.
    ///
    /// - Parameters:
    ///   - kind: The registered agent's on-disk layout kind.
    ///   - sessionDirectory: The agent's configured session directory.
    ///   - needle: The search text; empty matches every record.
    ///   - cwdFilter: When set, only records whose cwd equals it are kept.
    ///   - fileManager: The file manager used to probe and stat `history.jsonl`.
    public func resolveAntigravityHistory(
        kind: RegisteredAgentSessionIDKind,
        sessionDirectory: String?,
        needle: String,
        cwdFilter: String?,
        fileManager: FileManager = .default
    ) -> [AntigravityHistoryEntry] {
        let roots = registeredSessionRoots(
            kind: kind,
            sessionDirectory: sessionDirectory,
            cwdFilter: cwdFilter
        )
        guard !roots.isEmpty else { return [] }

        let fm = fileManager
        let fieldParser = AgentSessionFieldParser()
        let historyParser = AgentHistoryRecordParser(fieldParser: fieldParser)
        var latestBySessionID: [String: AntigravityHistoryEntry] = [:]

        for root in roots {
            if Task.isCancelled { break }
            let historyURL = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("history.jsonl", isDirectory: false)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: historyURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            let fallbackModified = ((try? fm.attributesOfItem(atPath: historyURL.path))?[.modificationDate] as? Date)
                ?? Date.distantPast

            ripgrepScanner.forEachJSONLine(url: historyURL, maxBytes: Int.max) { object in
                if Task.isCancelled { return true }
                guard let sessionId = fieldParser.firstString(in: object, keys: historyParser.antigravitySessionIDKeys()) else {
                    return false
                }
                let cwd = fieldParser.firstString(in: object, keys: historyParser.registeredJSONLCWDKeys())
                if let cwdFilter, cwd != cwdFilter { return false }

                let title = historyParser.antigravityHistoryTitle(in: object) ?? ""
                guard historyParser.antigravityHistoryMatchesNeedle(
                    needle: needle,
                    sessionId: sessionId,
                    title: title,
                    cwd: cwd
                ) else {
                    return false
                }

                let modified = historyParser.antigravityHistoryModifiedDate(in: object, fallback: fallbackModified)
                let entry = AntigravityHistoryEntry(
                    sessionId: sessionId,
                    title: title,
                    cwd: cwd,
                    modified: modified,
                    fileURL: historyURL
                )
                if let existing = latestBySessionID[sessionId] {
                    if entry.modified >= existing.modified {
                        latestBySessionID[sessionId] = entry
                    }
                } else {
                    latestBySessionID[sessionId] = entry
                }
                return false
            }
        }

        return latestBySessionID.values
            .sorted {
                if $0.modified == $1.modified {
                    return $0.sessionId < $1.sessionId
                }
                return $0.modified > $1.modified
            }
    }
}
