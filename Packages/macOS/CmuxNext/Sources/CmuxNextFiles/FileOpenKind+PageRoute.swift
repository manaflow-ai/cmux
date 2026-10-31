/// The file-page route shared by local and remote openers.
extension FileOpenKind {
    /// The view that shows a file or its source text.
    public enum PageRoute: Equatable, Sendable {
        /// A browser tab renders an HTML or SVG page.
        case renderedPage
        /// The Markdown page renders the document.
        case markdown
        /// The code editor shows the source text.
        case editor
        /// The browser previews an image, PDF or media file.
        case preview
    }

    /// Chooses the view before any file access. Open as Text selects source for rendered pages;
    /// remote callers may further restrict browser routes to avoid reading a local same-path file.
    public func pageRoute(asText: Bool = false) -> PageRoute {
        if opensAsText, asText { return .editor }
        switch self {
        case .web: return .renderedPage
        case .markdown: return .markdown
        case .preview: return .preview
        default: return .editor
        }
    }
}
