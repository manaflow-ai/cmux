import Foundation

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

        /// Chooses the view before file access. The Markdown page supports `.md` and `.markdown`;
        /// other Markdown aliases keep the code editor. Remote callers may restrict browser routes.
        public init(fileName: String, asText: Bool = false) {
            let kind = FileOpenKind(fileName: fileName, isDirectory: false, isPackage: false)
            if kind.opensAsText, asText { self = .editor; return }
            switch kind {
            case .web: self = .renderedPage
            case .markdown: self = ["md", "markdown"].contains((fileName as NSString).pathExtension.lowercased()) ? .markdown : .editor
            case .preview: self = .preview
            default: self = .editor
            }
        }
    }
}
