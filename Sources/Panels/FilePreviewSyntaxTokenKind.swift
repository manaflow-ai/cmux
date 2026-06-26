import Foundation

/// Classification produced by ``FilePreviewSyntaxTokenizer`` for a run of source
/// text. Only spans that get a non-default color are emitted; plain identifiers,
/// whitespace, and punctuation are left to the editor's base foreground color.
enum FilePreviewSyntaxTokenKind: Equatable, Sendable {
    case keyword
    case type
    case string
    case number
    case comment
    case function
    case attribute
}
