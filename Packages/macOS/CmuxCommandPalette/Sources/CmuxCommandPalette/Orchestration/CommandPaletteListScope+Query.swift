import Foundation

extension CommandPaletteListScope {
    /// Prefix that switches the palette query into the command list. A query
    /// beginning with this token resolves to ``CommandPaletteListScope/commands``;
    /// anything else resolves to ``CommandPaletteListScope/switcher``.
    public static let commandsPrefix = ">"

    /// Resolves the list scope for a raw palette `query`.
    ///
    /// A query that starts with ``commandsPrefix`` is the command list; every
    /// other query is the workspace/surface switcher.
    public static func scope(for query: String) -> CommandPaletteListScope {
        query.hasPrefix(commandsPrefix) ? .commands : .switcher
    }

    /// The stable list identity (`rawValue`) for a raw palette `query`, used to
    /// reset list-scoped UI state when the scope changes.
    public static func listIdentity(for query: String) -> String {
        scope(for: query).rawValue
    }

    /// Strips the command prefix (in `.commands`) and trims whitespace to
    /// produce the query the fuzzy matcher consumes for this scope.
    public static func queryForMatching(query: String, scope: CommandPaletteListScope) -> String {
        switch scope {
        case .commands:
            let suffix = String(query.dropFirst(commandsPrefix.count))
            return suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        case .switcher:
            return query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The effective query for a refresh: the live-observed query when present,
    /// otherwise the stored state query.
    public static func refreshQuery(stateQuery: String, observedQuery: String?) -> String {
        observedQuery ?? stateQuery
    }

    /// Whether the switcher should include per-surface entries: only in the
    /// switcher scope, only when "search all surfaces" is on, and only once the
    /// matching query is non-empty.
    public static func switcherIncludesSurfaceEntries(searchAllSurfaces: Bool, query: String) -> Bool {
        let scope = scope(for: query)
        guard scope == .switcher else { return false }
        return searchAllSurfaces && !queryForMatching(query: query, scope: scope).isEmpty
    }

    /// Whether a query transition crosses a scope boundary while results are
    /// visible, which requires resetting the visible-results pipeline.
    public static func shouldResetVisibleResultsForQueryTransition(
        oldQuery: String,
        newQuery: String,
        hasVisibleResults: Bool
    ) -> Bool {
        hasVisibleResults && scope(for: oldQuery) != scope(for: newQuery)
    }

    /// Resolved refresh inputs for a `(stateQuery, observedQuery, searchAllSurfaces)`
    /// triple: the scope raw value, the matching query, and whether surfaces are
    /// included. Exposed for deterministic unit coverage of the refresh path.
    public static func refreshInputs(
        stateQuery: String,
        observedQuery: String?,
        searchAllSurfaces: Bool
    ) -> (scope: String, matchingQuery: String, includesSurfaces: Bool) {
        let effectiveQuery = refreshQuery(stateQuery: stateQuery, observedQuery: observedQuery)
        let scope = scope(for: effectiveQuery)
        return (
            scope: scope.rawValue,
            matchingQuery: queryForMatching(query: effectiveQuery, scope: scope),
            includesSurfaces: switcherIncludesSurfaceEntries(
                searchAllSurfaces: searchAllSurfaces,
                query: effectiveQuery
            )
        )
    }
}
