public import CmuxFoundation

/// One searchable field of one sidebar row, prepared for repeated matching.
///
/// Preparation (normalize, split into characters and word segments, build the
/// ASCII mask) is the expensive half of fuzzy matching, and it depends only on
/// the candidate - not on the query. Building these once per corpus revision
/// and reusing them across keystrokes is what keeps per-character filtering off
/// the main thread's critical path.
public struct SidebarFilterCandidateField: Sendable {
    /// Which row field this text came from.
    public let field: SidebarFilterField
    /// The text as the row displays it, used to map match indices back to UI.
    public let displayText: String
    /// The normalized, pre-segmented form the matcher scores against.
    public let prepared: FuzzyMatcher.PreparedCandidateText
    /// Whether match offsets in normalized coordinates also address
    /// `displayText`.
    ///
    /// Search normalization case-folds and strips diacritics, which can change
    /// a string's character count. When it does, a matched offset no longer
    /// points at the same character in the displayed string, so the engine
    /// drops that field's highlight data rather than underlining the wrong
    /// characters. Scoring is unaffected either way.
    public let isDisplayIndexAligned: Bool

    /// Prepares `displayText` for matching as `field`.
    ///
    /// - Parameters:
    ///   - field: The row field this text is displayed in.
    ///   - displayText: The text exactly as the row renders it.
    public init(field: SidebarFilterField, displayText: String) {
        self.field = field
        self.displayText = displayText
        let normalizedText = FuzzyMatcher.normalizeForSearch(displayText)
        self.prepared = FuzzyMatcher.PreparedCandidateText(normalizedText: normalizedText)
        self.isDisplayIndexAligned = normalizedText.count == displayText.count
    }
}
