import CMUXAgentLaunch
import Foundation

extension SessionIndexStore {
    /// Loads Muse Code sessions from Muse's own read-only `session-index.db`.
    nonisolated static func loadMuseEntries(
        registration: CmuxVaultAgentRegistration,
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int,
        errorBag: ErrorBag,
        index: MuseSessionIndex = MuseSessionIndex()
    ) -> [SessionEntry] {
        let result = index.loadSessions(
            needle: needle,
            cwdFilter: cwdFilter,
            offset: offset,
            limit: limit
        )
        for error in result.errors {
            errorBag.addSafe(diagnostic: "Muse index failure: \(error)")
        }
        return result.sessions.map { session in
            SessionEntry(
                id: "\(registration.id):\(session.sessionId)",
                agent: .registered(RegisteredSessionAgent(registration: registration)),
                sessionId: session.sessionId,
                title: session.title,
                cwd: session.cwd,
                gitBranch: session.gitBranch,
                pullRequest: nil,
                modified: session.modified,
                fileURL: nil,
                specifics: .registered(registration)
            )
        }
    }

    #if DEBUG
    nonisolated static func loadMuseEntriesForTesting(
        indexDBPath: String,
        needle: String = "",
        cwdFilter: String? = nil,
        offset: Int = 0,
        limit: Int = 100
    ) -> SearchOutcome {
        let bag = ErrorBag()
        let entries = loadMuseEntries(
            registration: .builtInMuse,
            needle: needle,
            cwdFilter: cwdFilter,
            offset: offset,
            limit: limit,
            errorBag: bag,
            index: MuseSessionIndex(indexDatabasePath: indexDBPath)
        )
        return SearchOutcome(entries: entries, errors: bag.snapshot())
    }
    #endif
}
