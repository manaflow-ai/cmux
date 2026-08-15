import Foundation

// MARK: - Global (cross-agent) session search for the recency "All" view.

extension SessionIndexStore {
    /// Per-agent cap for the transcript-content phase of a global search.
    nonisolated static let globalSearchPerAgentLimit = 50
    /// Overall cap on merged global search results.
    nonisolated static let globalSearchResultCap = 200

    /// Searches every indexed session across all agents. Two bounded phases:
    /// metadata match against the already-loaded entries (free), then the
    /// existing capped per-agent transcript search for the free-text part of
    /// the query (issue #4535: no new scan primitives, existing caps reused).
    func searchAllSessions(rawQuery: String) async -> SearchOutcome {
        let query = VaultSessionSearchQuery.parse(rawQuery)
        guard !query.isEmpty else {
            return SearchOutcome(entries: [], errors: [])
        }

        var merged = entries.filter { query.matchesMetadata($0) }
        var errors: [String] = []

        let needle = query.residualText
        if !needle.isEmpty {
            let agents = globalSearchCandidateAgents(for: query)
            let outcomes = await withTaskGroup(of: SearchOutcome.self) { group in
                for agent in agents {
                    group.addTask { [weak self] in
                        guard let self else { return SearchOutcome(entries: [], errors: []) }
                        return await self.searchSessions(
                            query: needle,
                            scope: .agent(agent),
                            offset: 0,
                            limit: Self.globalSearchPerAgentLimit
                        )
                    }
                }
                var collected: [SearchOutcome] = []
                for await outcome in group { collected.append(outcome) }
                return collected
            }
            for outcome in outcomes {
                errors.append(contentsOf: outcome.errors)
                merged.append(contentsOf: outcome.entries.filter { query.matchesOperators($0) })
            }
        }

        if scopeToCurrentDirectory, let scoped = Self.normalizedGlobalSearchDirectory(currentDirectory) {
            merged = merged.filter { entry in
                guard let cwd = Self.normalizedGlobalSearchDirectory(entry.cwd) else { return false }
                return cwd == scoped || cwd.hasPrefix(scoped + "/")
            }
        }

        let ranked = VaultSessionSearchRanking.rank(merged, query: query)
        return SearchOutcome(
            entries: Array(ranked.prefix(Self.globalSearchResultCap)),
            errors: errors.sorted()
        )
    }

    /// Agents worth fanning the transcript search across: all built-ins plus
    /// any registered agents visible in the loaded index, narrowed by
    /// `agent:` operators when present.
    private func globalSearchCandidateAgents(for query: VaultSessionSearchQuery) -> [SessionAgent] {
        var agents = SessionAgent.builtInCases
        var seen = Set(agents.map(\.rawValue))
        for entry in entries {
            if case .registered = entry.agent, seen.insert(entry.agent.rawValue).inserted {
                agents.append(entry.agent)
            }
        }
        guard !query.agentTerms.isEmpty else { return agents }
        return agents.filter { agent in
            let rawValue = agent.rawValue.lowercased()
            let display = agent.displayName.lowercased()
            return query.agentTerms.contains { rawValue.contains($0) || display.contains($0) }
        }
    }

    nonisolated private static func normalizedGlobalSearchDirectory(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        var path = (value as NSString).standardizingPath
        if path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
