/// Bounds syntax-highlighting work and selects the plain-text degradation path.
public struct FilePreviewSyntaxHighlightPolicy: Equatable, Sendable {
    /// Maximum UTF-16 source length eligible for highlighting.
    public let maximumUTF16Length: Int

    /// Maximum colored spans accepted from one scan.
    public let maximumTokenCount: Int

    /// Creates a highlighting work policy.
    ///
    /// - Parameters:
    ///   - maximumUTF16Length: Source-length cap. Defaults to 600,000 UTF-16 units.
    ///   - maximumTokenCount: Colored-span cap. Defaults to 12,000 tokens.
    public init(
        maximumUTF16Length: Int = 600_000,
        maximumTokenCount: Int = 12_000
    ) {
        self.maximumUTF16Length = max(0, maximumUTF16Length)
        self.maximumTokenCount = max(0, maximumTokenCount)
    }

    /// Returns whether a source should enter the highlighting pipeline.
    ///
    /// Disabled, unsupported, and oversized sources render as plain text.
    ///
    /// - Parameters:
    ///   - enabled: The user's syntax-highlighting preference.
    ///   - language: The language resolved from the filename.
    ///   - utf16Length: Current source length in UTF-16 code units.
    /// - Returns: `true` only when highlighting work is allowed.
    public func allowsHighlighting(
        enabled: Bool,
        language: FilePreviewSyntaxLanguage?,
        utf16Length: Int
    ) -> Bool {
        enabled && language != nil && utf16Length <= maximumUTF16Length
    }

    /// Returns whether a completed scan may be displayed.
    ///
    /// - Parameter result: The bounded scanner result.
    /// - Returns: `false` for cancellation or token-limit overflow.
    public func accepts(_ result: FilePreviewSyntaxHighlightResult) -> Bool {
        !result.wasCancelled && !result.didExceedTokenLimit
    }
}
