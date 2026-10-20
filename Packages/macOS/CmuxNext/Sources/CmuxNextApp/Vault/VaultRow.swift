import CmuxNextHistory
import Foundation

/// One session in the vault list: an immutable snapshot (rows hold no store).
nonisolated struct VaultRow: Identifiable, Hashable, Sendable {
    let session: AgentSession
    /// The agent still runs in a tab this app shows (Focus Session applies).
    let isLive: Bool
    /// "Claude Code in cmux" (`HistoryAppStrings.agentTitle`).
    let title: String

    /// `<machine>/<provider>/<session id>`.
    var id: String { session.qualifiedID }
    /// The working directory, with the home folder as `~`.
    var detail: String? {
        guard let cwd = session.cwd, !cwd.isEmpty else { return nil }
        let home = NSHomeDirectory()
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }
    /// cmux knows the provider's resume flag.
    var canResume: Bool { session.resumeCommand != nil }

    /// Whether `query` (case-insensitive) matches the title, folder, provider or session id.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [title, session.cwd ?? "", session.provider, session.sessionID]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
