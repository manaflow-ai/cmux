import CMUXAgentLaunch
import CmuxFoundation
import Foundation

extension SessionIndexStore {
    /// SQL-backed Codex loader. Returns nil if `state_5.sqlite` doesn't exist
    /// so the caller can fall back to the disk scan.
    ///
    /// The SQLite read (snapshot + query + row decode + needle match) lives in
    /// `CMUXAgentLaunch.CodexThreadSQLResolver`; this loader is the thin app-side
    /// seam that constructs the resolver with the app's `ripgrepScanner` and
    /// `searchMaxFiles`, then maps each `CodexThreadRecord` onto a `SessionEntry`.
    nonisolated static func loadCodexEntriesViaSQL(
        needle: String, cwdFilter: String?, offset: Int, limit: Int,
        errorBag: ErrorBag,
        dbPath: String = ("~/.codex/state_5.sqlite" as NSString).expandingTildeInPath,
        sessionsRoot: String = (CodexSessionResolver().codexSessionsRoot(env: [:]) as NSString).standardizingPath
    ) async -> [SessionEntry]? {
        let resolver = CodexThreadSQLResolver(
            ripgrepScanner: ripgrepScanner,
            searchMaxFiles: searchMaxFiles,
            fileManager: .default,
            dbPath: dbPath,
            sessionsRoot: sessionsRoot
        )
        guard let records = await resolver.loadRecords(
            needle: needle,
            cwdFilter: cwdFilter,
            offset: offset,
            limit: limit,
            errorBag: errorBag
        ) else {
            return nil
        }
        return records.map(codexEntry(from:))
    }

    #if DEBUG
    nonisolated static func loadCodexEntriesForTesting(
        stateDBPath: String,
        needle: String,
        cwdFilter: String? = nil,
        offset: Int = 0,
        limit: Int = 100,
        sessionsRoot: String = (CodexSessionResolver().codexSessionsRoot(env: [:]) as NSString).standardizingPath
    ) async -> SearchOutcome {
        let bag = ErrorBag()
        let entries = await loadCodexEntriesViaSQL(
            needle: needle.lowercased(),
            cwdFilter: cwdFilter,
            offset: offset,
            limit: limit,
            errorBag: bag,
            dbPath: stateDBPath,
            sessionsRoot: sessionsRoot
        ) ?? []
        return SearchOutcome(entries: entries, errors: bag.snapshot())
    }
    #endif

    nonisolated private static func codexEntry(from record: CodexThreadRecord) -> SessionEntry {
        let sandboxMode = record.sandboxJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["type"] as? String }

        let displayTitle: String
        if !record.titleField.isEmpty {
            displayTitle = record.titleField
        } else if let real = ripgrepScanner.realCodexUserMessage(record.firstUserMessage) {
            displayTitle = real
        } else {
            displayTitle = ""
        }

        let fileURL = record.normalizedRolloutPath.map { URL(fileURLWithPath: $0) }
        return SessionEntry(
            id: "codex:" + (fileURL?.path ?? record.sessionId),
            agent: .codex,
            sessionId: record.sessionId,
            title: displayTitle,
            cwd: record.cwd,
            gitBranch: record.gitBranch?.isEmpty == false ? record.gitBranch : nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: TimeInterval(record.updatedMs) / 1000.0),
            fileURL: fileURL,
            specifics: .codex(
                model: record.model?.isEmpty == false ? record.model : nil,
                approvalPolicy: record.approvalMode?.isEmpty == false ? record.approvalMode : nil,
                sandboxMode: sandboxMode,
                effort: record.reasoningEffort?.isEmpty == false ? record.reasoningEffort : nil
            )
        )
    }
}
