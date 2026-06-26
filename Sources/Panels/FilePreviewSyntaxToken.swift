import Foundation

/// A colored span of source text, expressed as a UTF-16 ``NSRange`` so it can be
/// applied directly to an `NSTextStorage` / `NSLayoutManager`.
struct FilePreviewSyntaxToken: Equatable, Sendable {
    let range: NSRange
    let kind: FilePreviewSyntaxTokenKind
}
