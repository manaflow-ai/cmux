enum FilePreviewSyntaxHighlightDecision: Equatable, Sendable {
    case highlight(language: String?)
    case skip
}
