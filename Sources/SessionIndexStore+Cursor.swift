import CMUXAgentLaunch
import Foundation

extension SessionIndexStore {
    nonisolated static func loadCursorEntries(
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int,
        errorBag: ErrorBag,
        index: CursorSessionIndex = CursorSessionIndex()
    ) async -> [SessionEntry] {
        let result = await index.loadSessions(
            needle: needle,
            workingDirectoryFilter: cwdFilter,
            offset: offset,
            limit: limit
        )
        for error in result.errors {
            errorBag.add(localizedCursorIndexError(error))
        }
        return result.sessions.map { session in
            SessionEntry(
                id: "cursor:" + session.transcriptURL.path,
                agent: .cursor,
                sessionId: session.sessionID,
                title: session.title,
                cwd: session.workingDirectory,
                gitBranch: nil,
                pullRequest: nil,
                modified: session.modifiedAt,
                fileURL: session.transcriptURL,
                specifics: .cursor
            )
        }
    }

    private nonisolated static func localizedCursorIndexError(
        _ error: CursorSessionIndexError
    ) -> String {
        switch error {
        case .projectsDirectoryUnreadable:
            return String(
                localized: "sessionIndex.error.cursorProjects",
                defaultValue: "Cursor: cannot read local sessions"
            )
        case .transcriptUnreadable:
            return String(
                localized: "sessionIndex.error.cursorTranscript",
                defaultValue: "Cursor: cannot read one or more transcripts"
            )
        }
    }
}
