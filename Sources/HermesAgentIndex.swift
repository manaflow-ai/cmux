import CMUXHermesAgentIndex
import Foundation

extension SessionIndexStore {
    nonisolated static func loadHermesAgentEntries(
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int,
        errorBag: ErrorBag,
        stateDBPath: String = HermesAgentIndex.defaultStateDBPath()
    ) -> [SessionEntry] {
        let result = HermesAgentIndex.loadSessions(
            needle: needle,
            cwdFilter: cwdFilter,
            offset: offset,
            limit: limit,
            stateDBPath: stateDBPath
        )
        for error in result.errors {
            errorBag.add(error)
        }
        return result.sessions.map { session in
            SessionEntry(
                id: "hermes-agent:" + session.sessionId,
                agent: .hermesAgent,
                sessionId: session.sessionId,
                title: session.title,
                cwd: nil,
                gitBranch: nil,
                pullRequest: nil,
                modified: session.modified,
                fileURL: nil,
                specifics: .hermesAgent(source: session.source, model: session.model)
            )
        }
    }

    #if DEBUG
    nonisolated static func loadHermesAgentEntriesForTesting(
        stateDBPath: String,
        needle: String = "",
        cwdFilter: String? = nil,
        offset: Int = 0,
        limit: Int = 100
    ) -> SearchOutcome {
        let bag = ErrorBag()
        let entries = loadHermesAgentEntries(
            needle: needle,
            cwdFilter: cwdFilter,
            offset: offset,
            limit: limit,
            errorBag: bag,
            stateDBPath: stateDBPath
        )
        return SearchOutcome(entries: entries, errors: bag.snapshot())
    }
    #endif
}
