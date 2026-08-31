public import CmuxFoundation

/// The command palette's name for the shared ``FuzzyMatcher``.
///
/// The matcher moved down to `CmuxFoundation` when the sidebar workspace
/// filter needed the same scoring: two domain packages may not depend on each
/// other, so the shared primitive lifts to the common lower package. This
/// alias keeps every palette call site (and its reference-scoring tests)
/// spelled as before.
public typealias CommandPaletteFuzzyMatcher = FuzzyMatcher
