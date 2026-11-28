// Ported from fzf, Copyright (c) 2013-2026 Junegunn Choi, MIT License.
// https://github.com/junegunn/fzf/blob/master/src/pattern.go

/// One parsed term of an fzf extended-search query (fzf's `term`).
struct FzfQueryTerm: Sendable, Equatable {
    /// How the term matches.
    let type: FzfTermType
    /// Whether the term must NOT match (`!`).
    let inverse: Bool
    /// The term text, lowercased when the term is case-insensitive.
    let text: String
    /// Whether the term respects case (smart case: it contains an uppercase letter).
    let caseSensitive: Bool
}
