import Foundation

extension SessionIndexStore {
    /// Resolves one exact conversation through the provider-specific Sessions index.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated static func resolveConversationEntry(
        source: AgentConversationSource
    ) async -> SessionEntry? {
        var registrations = CmuxVaultAgentRegistry.load(
            workingDirectory: source.workingDirectory
        ).registrations
        if let registration = source.registration {
            registrations.append(registration)
        }
        let registry = CmuxVaultAgentRegistry(registrations: registrations)
        let errorBag = ErrorBag()

        func exactMatch(in entries: [SessionEntry]) -> SessionEntry? {
            entries.first { $0.sessionId == source.sessionId }
        }

        for cwdFilter in [source.workingDirectory, nil] {
            let directMatches = await searchAgent(
                needle: source.sessionId,
                agent: source.sessionAgent,
                cwdFilter: cwdFilter,
                offset: 0,
                limit: 64,
                errorBag: errorBag,
                registry: registry
            )
            if let match = exactMatch(in: directMatches) {
                return match
            }
            if cwdFilter == nil {
                break
            }
        }

        // Some indexes search transcript text rather than IDs. Enumerate their
        // bounded metadata view and match the native session ID after indexing.
        for cwdFilter in [source.workingDirectory, nil] {
            let entries = await searchAgent(
                needle: "",
                agent: source.sessionAgent,
                cwdFilter: cwdFilter,
                offset: 0,
                limit: 2_000,
                errorBag: errorBag,
                registry: registry
            )
            if let match = exactMatch(in: entries) {
                return match
            }
            if cwdFilter == nil {
                break
            }
        }
        return nil
    }
}
