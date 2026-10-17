/// One document-level Markdown block with structure preserved for layout.
struct ChatArtifactMarkdownBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case paragraph
        case bullet(indent: Int)
        case ordered(marker: String, indent: Int)
        case quote
        case rule
        case code(language: String?)
        case tableRow(isHeader: Bool)
    }

    let index: Int
    let kind: Kind
    let text: String

    var id: Int { index }
}
