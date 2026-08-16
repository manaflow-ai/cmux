import Foundation

// MARK: - Global (cross-agent) session search for the recency "All" view and
// the `cmux vault search` socket surface.

extension SessionIndexStore {
    /// Per-agent cap for the transcript-content phase of a global search.
    nonisolated static let globalSearchPerAgentLimit = 50
    /// Overall cap on merged global search results.
    nonisolated static let globalSearchResultCap = 200
    /// Transcript searches run per free-text term; only the most selective
    /// (longest) few terms fan out to keep total work bounded.
    nonisolated static let globalSearchMaxTranscriptTerms = 3

    /// Instance wrapper used by the Vault UI: searches over the loaded index
    /// with the store's folder scope applied.
    func searchAllSessions(rawQuery: String) async -> SearchOutcome {
        await Self.searchAllSessions(
            rawQuery: rawQuery,
            entries: entries,
            scopedDirectory: scopeToCurrentDirectory ? currentDirectory : nil
        )
    }

    /// Store-free core (also the `vault.search` socket handler's engine).
    /// Two bounded phases: metadata match against `entries`, then the
    /// existing capped per-agent transcript search for the free-text part of
    /// the query (issue #4535: no new scan primitives, existing caps reused).
    nonisolated static func searchAllSessions(
        rawQuery: String,
        entries: [SessionEntry],
        scopedDirectory: String?
    ) async -> SearchOutcome {
        let query = VaultSessionSearchQuery.parse(rawQuery)
        guard !query.isEmpty else {
            return SearchOutcome(entries: [], errors: [])
        }

        var merged = entries.filter { query.matchesMetadata($0) }
        var errors: [String] = []

        // Transcript phase: the underlying per-agent search matches one
        // literal needle, so a multi-word query runs one bounded search per
        // term (the most selective few) and intersects the results — "flaky
        // test" finds transcripts containing both words, not only the exact
        // phrase. The per-agent caps make this an approximation for terms
        // with more matches than the cap; that is the bounded-work tradeoff.
        let needleTerms = Array(
            query.textTerms
                .sorted { $0.count > $1.count }
                .prefix(Self.globalSearchMaxTranscriptTerms)
        )
        if !needleTerms.isEmpty {
            let agents = globalSearchCandidateAgents(for: query, entries: entries)
            let registry = await vaultAgentRegistry(workingDirectory: scopedDirectory)
            var perTermIDs: [Set<String>] = []
            var transcriptEntriesByID: [String: SessionEntry] = [:]
            for term in needleTerms {
                // A cancelled search must not merge partial per-term results —
                // an intersection over fewer terms admits entries that only
                // match a subset of the query.
                if Task.isCancelled { return SearchOutcome(entries: [], errors: []) }
                let bag = ErrorBag()
                let outcomes = await withTaskGroup(of: [SessionEntry].self) { group in
                    for agent in agents {
                        // Grok and registered agents take the folder scope as
                        // their cwd filter, mirroring `searchSessions`'s
                        // per-scope behavior.
                        let cwdFilter: String?
                        switch agent {
                        case .grok, .registered:
                            cwdFilter = scopedDirectory
                        default:
                            cwdFilter = nil
                        }
                        group.addTask {
                            await Self.searchAgent(
                                needle: term.lowercased(),
                                agent: agent,
                                cwdFilter: cwdFilter,
                                offset: 0,
                                limit: Self.globalSearchPerAgentLimit,
                                errorBag: bag,
                                registry: registry
                            )
                        }
                    }
                    var collected: [[SessionEntry]] = []
                    for await result in group { collected.append(result) }
                    return collected
                }
                errors.append(contentsOf: bag.snapshot())
                var termIDs: Set<String> = []
                for result in outcomes {
                    for entry in result where query.matchesOperators(entry) {
                        termIDs.insert(entry.id)
                        transcriptEntriesByID[entry.id] = entry
                    }
                }
                perTermIDs.append(termIDs)
            }
            if let first = perTermIDs.first {
                let intersected = perTermIDs.dropFirst().reduce(first) { $0.intersection($1) }
                merged.append(contentsOf: intersected.compactMap { transcriptEntriesByID[$0] })
            }
        }

        if let scoped = Self.normalizedGlobalSearchDirectory(scopedDirectory) {
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
    nonisolated private static func globalSearchCandidateAgents(
        for query: VaultSessionSearchQuery,
        entries: [SessionEntry]
    ) -> [SessionAgent] {
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
