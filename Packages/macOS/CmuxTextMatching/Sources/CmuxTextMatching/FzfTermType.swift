// Ported from fzf, Copyright (c) 2013-2026 Junegunn Choi, MIT License.
// https://github.com/junegunn/fzf/blob/master/src/pattern.go

/// How one term of an fzf extended-search query matches (fzf's `termType`).
enum FzfTermType: Sendable, Equatable {
    /// A fuzzy subsequence (`abc`).
    case fuzzy
    /// An exact substring (`'abc`, or any inverse term).
    case exact
    /// An exact substring on word boundaries (`'abc'`).
    case exactBoundary
    /// Anchored at the start (`^abc`).
    case prefix
    /// Anchored at the end (`abc$`).
    case suffix
    /// The whole text (`^abc$`).
    case equal
}
