/// One piece of a message's text after ``HomeMermaidSplitter`` cut out its
/// Mermaid fences.
///
/// The pieces cover the whole text in order: joining every segment's
/// ``original`` gives back the text exactly.
public enum HomeTextSegment: Hashable, Sendable {
    /// Text outside any Mermaid fence, as written (other fenced blocks included).
    case text(String)
    /// A closed ```` ```mermaid ```` (or `~~~mermaid`) block.
    ///
    /// - `source`: the lines between the fences, with the opening fence's
    ///   indentation removed; what a diagram renderer draws and what Copy gives.
    /// - `fenced`: the block as written, fence lines included; what the
    ///   transcript shows when the source does not render.
    case mermaid(source: String, fenced: String)

    /// The segment as it was written in the message.
    public var original: String {
        switch self {
        case .text(let text): text
        case .mermaid(_, let fenced): fenced
        }
    }
}
