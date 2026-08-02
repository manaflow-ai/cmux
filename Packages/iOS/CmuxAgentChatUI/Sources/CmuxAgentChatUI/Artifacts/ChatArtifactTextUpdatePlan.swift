import Foundation

/// Determines whether a TextKit update needs an expensive full-document snapshot.
struct ChatArtifactTextUpdatePlan: Equatable, Sendable {
    let requiresFullTextSnapshot: Bool

    init(
        reachedEOF: Bool,
        highlightDecision: ChatArtifactHighlightDecision,
        searchQuery: String
    ) {
        let requiresHighlightText: Bool
        if reachedEOF, case .highlight = highlightDecision {
            requiresHighlightText = true
        } else {
            requiresHighlightText = false
        }
        requiresFullTextSnapshot = requiresHighlightText || !searchQuery.isEmpty
    }
}
