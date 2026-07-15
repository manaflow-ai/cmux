import Foundation

extension SessionIndexStore {
    /// Fresh, cwd-scoped entries across every agent, bypassing the snapshot
    /// cache. Used by the Notes tree to re-resolve session-folder markers
    /// against live session data with the exact scanners the Vault uses, so a
    /// dragged-in session's title/recency keeps tracking the real session.
    nonisolated static func loadLiveSessionEntries(cwdFilter: String, limit: Int = 10_000) async -> [SessionEntry] {
        let bag = ErrorBag()
        let order = await defaultAgentOrder(workingDirectory: cwdFilter)
        return await loadAgents(
            order.agents,
            registry: order.registry,
            needle: "",
            cwdFilter: cwdFilter,
            offset: 0,
            limit: max(1, limit),
            errorBag: bag
        )
    }

}
