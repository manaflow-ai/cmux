/// The bounded outcome of one syntax-highlighting scan.
public struct FilePreviewSyntaxHighlightResult: Equatable, Sendable {
    /// Highlighted spans, empty when scanning was cancelled or exceeded its token limit.
    public let tokens: [FilePreviewSyntaxToken]

    /// Whether scanning stopped because it produced more tokens than the caller allowed.
    public let didExceedTokenLimit: Bool

    /// Whether scanning observed cooperative task cancellation.
    public let wasCancelled: Bool
}
