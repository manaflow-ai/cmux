/// Describes whether and how a loaded text artifact should be syntax highlighted.
enum ChatArtifactHighlightDecision: Equatable, Sendable {
    case highlight(language: String?)
    case skippedForSize
    case skippedNoLanguage

    /// Whether the size-threshold explanation belongs in the viewer chrome.
    var showsHighlightingOffPill: Bool {
        self == .skippedForSize
    }
}
