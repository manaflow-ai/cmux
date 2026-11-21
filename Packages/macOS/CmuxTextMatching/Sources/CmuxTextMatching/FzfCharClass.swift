// Ported from fzf, Copyright (c) 2013-2026 Junegunn Choi, MIT License.
// https://github.com/junegunn/fzf/blob/master/src/algo/algo.go

/// The character classes fzf's scorer distinguishes, in fzf's order.
///
/// The raw values matter: fzf compares classes with `>=` (everything from
/// ``nonWord`` up starts a word after whitespace or a delimiter).
enum FzfCharClass: Int, Sendable, CaseIterable {
    case white = 0
    case nonWord
    case delimiter
    case lower
    case upper
    case letter
    case number
}
