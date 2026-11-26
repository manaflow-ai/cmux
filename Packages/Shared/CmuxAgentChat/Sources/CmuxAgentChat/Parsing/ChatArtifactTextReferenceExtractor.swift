/// Extracts absolute artifact tokens from raw transcript text using the same
/// detector as terminal In-view affordances.
struct ChatArtifactTextReferenceExtractor: Sendable {
    private let detector = TerminalArtifactPathDetector()

    /// Returns absolute or home-relative detector tokens in display order.
    ///
    /// Relative free-text tokens intentionally remain out of scope because
    /// the working directory at mention time is unknowable.
    ///
    /// - Parameter text: Raw, pre-budget transcript text.
    /// - Returns: De-duplicated absolute candidates.
    func paths(in text: String) -> [String] {
        detector.paths(in: text).filter(ChatArtifactPathNormalizer.isAbsoluteFreeTextCandidate)
    }
}
