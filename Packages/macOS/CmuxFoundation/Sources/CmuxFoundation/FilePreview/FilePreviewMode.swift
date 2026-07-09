/// The viewer kind the file-preview panel uses to render a file.
///
/// Resolved from a file's extension, filename, and (for ambiguous cases)
/// sniffed bytes by ``FilePreviewKindResolver``.
public enum FilePreviewMode: Equatable, Sendable {
    case text
    case pdf
    case image
    case media
    case quickLook

    /// SF Symbol name shown on the preview tab for this mode.
    public var iconName: String {
        switch self {
        case .text:
            return "doc.text"
        case .pdf:
            return "doc.richtext"
        case .image:
            return "photo"
        case .media:
            return "play.rectangle"
        case .quickLook:
            return "doc.viewfinder"
        }
    }
}
