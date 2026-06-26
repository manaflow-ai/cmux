import Foundation

/// Pure query/scope policy for the command palette.
///
/// Resolves which list a query selects (the `>`-prefixed command list or the
/// workspace/surface switcher), the query text used for matching within a
/// scope, whether the switcher should include surface entries, the per-query
/// list identity, the visible-results reset decision across a query transition,
/// and the fork-command priority boost. All of it is a deterministic transform
/// over the query string plus the configured command-list prefix, so the policy
/// is a `Sendable` value with no isolation: it is the single source of truth
/// every command-palette surface forwards these decisions to.
public struct CommandPaletteQueryScopePolicy: Sendable, Equatable {
    /// The query prefix that selects the command-list scope.
    public let commandsPrefix: String

    /// Creates a policy with the given command-list prefix (default `">"`).
    public init(commandsPrefix: String = ">") {
        self.commandsPrefix = commandsPrefix
    }

    /// The list scope for `query`: the `>`-prefixed command list or the
    /// workspace/surface switcher.
    public func listScope(for query: String) -> CommandPaletteListScope {
        query.hasPrefix(commandsPrefix) ? .commands : .switcher
    }

    /// The stable list identity for `query`, used to detect list transitions.
    public func listIdentity(for query: String) -> String {
        listScope(for: query).rawValue
    }

    /// Whether the visible results should be reset when the query transitions
    /// from `oldQuery` to `newQuery`: only when results are visible and the two
    /// queries resolve to different scopes.
    public func shouldResetVisibleResultsForQueryTransition(
        oldQuery: String,
        newQuery: String,
        hasVisibleResults: Bool
    ) -> Bool {
        hasVisibleResults && listScope(for: oldQuery) != listScope(for: newQuery)
    }

    /// The query text used for matching within `scope`: the trimmed remainder
    /// after the command prefix for the command list, or the trimmed query for
    /// the switcher.
    public func queryForMatching(query: String, scope: CommandPaletteListScope) -> String {
        switch scope {
        case .commands:
            let suffix = String(query.dropFirst(commandsPrefix.count))
            return suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        case .switcher:
            return query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Whether the switcher list should include surface entries for `query`:
    /// only in the switcher scope, when all-surface search is on and the
    /// matching query is non-empty.
    public func switcherIncludesSurfaceEntries(searchAllSurfaces: Bool, query: String) -> Bool {
        let scope = listScope(for: query)
        guard scope == .switcher else { return false }
        return searchAllSurfaces && !queryForMatching(query: query, scope: scope).isEmpty
    }

    /// The priority boost applied to the fork-conversation command when the
    /// normalized query is exactly `fork`, so it sorts to the top.
    public func forkPriorityBoost(commandId: String, query: String) -> Int {
        guard CommandPaletteFuzzyMatcher.normalizeForSearch(query) == "fork",
              commandId == "palette.forkAgentConversationRight" else {
            return 0
        }
        return 10_000
    }
}
