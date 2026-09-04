import CmuxVaultHistory
import Foundation

/// Projects Vault session index entries into history events at read time.
///
/// Sessions are already durably indexed by Vault from the agents' own
/// on-disk stores, so the timeline derives them instead of double-writing:
/// whatever the session index covers automatically appears in History.
struct VaultHistorySessionEventProjection: Sendable {
    /// Returns projected session events in deterministic newest-first order.
    func events(from entries: [SessionEntry]) -> [VaultHistoryEvent] {
        entries
            .map { entry in
                VaultHistoryEvent(
                    id: "session:\(entry.agent.rawValue):\(entry.id)",
                    timestamp: entry.modified,
                    kind: .sessionActivity,
                    title: entry.title,
                    subject: VaultHistorySubject(
                        sessionId: entry.sessionId,
                        agent: entry.agent.rawValue,
                        directory: entry.cwd
                    )
                )
            }
            .sorted(by: VaultHistoryEvent.newestFirst)
    }
}
