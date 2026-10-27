package import CmuxNextHistory
package import Foundation

/// One session in the vault list: an immutable snapshot (rows hold no store).
package nonisolated struct VaultRow: Identifiable, Hashable, Sendable {
    package let session: AgentSession
    /// The agent still runs in a tab this app shows (Focus Session applies).
    package let isLive: Bool
    /// "Claude Code in cmux" (`HistoryAppStrings.agentTitle`).
    package let title: String

    /// `<machine>/<provider>/<session id>`.
    package var id: String { session.qualifiedID }
    /// The working directory, with the home folder as `~`.
    package var detail: String? {
        guard let cwd = session.cwd, !cwd.isEmpty else { return nil }
        let home = NSHomeDirectory()
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }
    /// cmux knows the provider's resume flag.
    package var canResume: Bool { session.resumeCommand != nil }

    /// Whether `query` (case-insensitive) matches the title, folder, provider or session id.
    package func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [title, session.cwd ?? "", session.provider, session.sessionID]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    package init(session: AgentSession, isLive: Bool, title: String) {
        self.session = session
        self.isLive = isLive
        self.title = title
    }
}
