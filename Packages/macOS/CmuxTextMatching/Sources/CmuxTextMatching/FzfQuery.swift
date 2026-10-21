// Ported from fzf, Copyright (c) 2013-2026 Junegunn Choi, MIT License.
// https://github.com/junegunn/fzf/blob/master/src/pattern.go

/// A query in fzf's extended-search syntax.
public struct FzfQuery: Sendable {
    let termSets: [[FzfQueryTerm]]
    let algorithm: FzfAlgorithm

    /// Parses `query`.
    public init(_ query: String, scheme: FzfScheme = .default) {
        self.algorithm = FzfAlgorithm(scheme: scheme)
        self.termSets = []
    }

    /// Whether the query has no terms and so matches everything.
    public var isEmpty: Bool { termSets.isEmpty }

    /// Matches `text`.
    public func match(_ text: String) -> FzfQueryMatch? { nil }
}
