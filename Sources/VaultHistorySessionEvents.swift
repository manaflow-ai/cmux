import Foundation

/// Projects Vault session index entries into history events at read time.
///
/// Sessions are already durably indexed by Vault from the agents' own
/// on-disk stores, so the timeline derives them instead of double-writing:
/// whatever the session index covers automatically appears in History.
struct VaultHistorySessionEventProjection: Sendable {
    func events(
        from entries: [SessionEntry],
        bindings: [VaultHistoryAgentBindingStore.Key: VaultHistoryAgentBindingStore.Binding] = [:]
    ) -> [VaultHistoryEvent] {
        entries.map { entry in
            let binding = bindings[VaultHistoryAgentBindingStore.Key(
                agentId: entry.agent.rawValue,
                sessionId: entry.sessionId
            )]
            return VaultHistoryEvent(
                id: "session:\(entry.agent.rawValue):\(entry.id)",
                timestamp: entry.modified,
                kind: .sessionActivity,
                title: entry.title,
                subject: VaultHistorySubject(
                    workspaceId: binding?.workspaceId,
                    surfaceId: binding?.surfaceId,
                    sessionId: entry.sessionId,
                    agent: entry.agent.rawValue,
                    agentDisplayName: entry.agent.displayName,
                    directory: entry.cwd
                )
            )
        }
    }
}
