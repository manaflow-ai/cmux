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
                cwd: session.cwd,
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

    private nonisolated static func hermesHomeForResume(stateDBPath: String) -> String {
        let stateDBURL = URL(fileURLWithPath: stateDBPath).standardizedFileURL
        return stateDBURL.deletingLastPathComponent().path
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
        let requestedHome = hermesHome?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinnedHome = requestedHome.flatMap { $0.isEmpty ? nil : $0 }
            ?? HermesAgentSessionResolver.hermesHome(env: ["HOME": NSHomeDirectory()])
        // A root HERMES_HOME still follows Hermes's sticky active_profile. Select
        // the default profile explicitly so the command opens the state.db that
        // produced this Vault row. Named profile paths are already authoritative.
        if URL(fileURLWithPath: pinnedHome).deletingLastPathComponent().lastPathComponent != "profiles" {
            parts.append("--profile default")
        }
        if source == "tui" {
            parts.append("--tui")
        }
        parts.append("--resume \(Self.shellQuote(sessionId))")
        if let model, !model.isEmpty {
            parts.append("--model \(Self.shellQuote(model))")
        }
        let command = parts.joined(separator: " ")
        return "env HERMES_HOME=\(Self.shellQuote(pinnedHome)) \(command)"
    }
}
