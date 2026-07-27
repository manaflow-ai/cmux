import CMUXAgentLaunch
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
                specifics: .hermesAgent(
                    source: session.source,
                    model: session.model,
                    hermesHome: hermesHomeForResume(stateDBPath: stateDBPath)
                )
            )
        }
    }

    private nonisolated static func hermesHomeForResume(stateDBPath: String) -> String? {
        let stateDBURL = URL(fileURLWithPath: stateDBPath).standardizedFileURL
        let homeURL = stateDBURL.deletingLastPathComponent()
        let defaultStateDBURL = URL(
            fileURLWithPath: HermesAgentIndex.defaultStateDBPath(env: ["HOME": NSHomeDirectory()])
        ).standardizedFileURL
        let defaultHomeURL = defaultStateDBURL.deletingLastPathComponent()
        return homeURL == defaultHomeURL ? nil : homeURL.path
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

extension SessionEntry {
    static func hermesResumeCommand(sessionId: String, source: String?, model: String?, hermesHome: String?) -> String {
        var parts = ["hermes"]
        if source == "tui" {
            parts.append("--tui")
        }
        parts.append("--resume \(Self.shellQuote(sessionId))")
        if let model, !model.isEmpty {
            parts.append("--model \(Self.shellQuote(model))")
        }
        let command = parts.joined(separator: " ")
        guard let hermesHome, !hermesHome.isEmpty else {
            return command
        }
        return "env HERMES_HOME=\(Self.shellQuote(hermesHome)) \(command)"
    }
}
