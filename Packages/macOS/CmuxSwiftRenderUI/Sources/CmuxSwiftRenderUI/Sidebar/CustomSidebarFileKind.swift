import Foundation

/// File format used by a custom sidebar source file.
public enum CustomSidebarFileKind: String, Sendable {
    /// Runtime SwiftUI-style interpreted sidebar source.
    case swift

    /// Declarative JSON sidebar document.
    case json

    /// Local HTML document rendered in a web view.
    case html

    /// Shortcut file naming an `http`/`https` page to render in a web view.
    case url

    /// Classifies a file by extension, or `nil` when it is not a sidebar file.
    ///
    /// - Parameter fileURL: The candidate file.
    public init?(fileURL: URL) {
        self.init(rawValue: fileURL.pathExtension.lowercased())
    }

    /// Whether this kind renders through the interpreter rather than a web view.
    public var isInterpreted: Bool {
        switch self {
        case .swift, .json: return true
        case .html, .url: return false
        }
    }
}
