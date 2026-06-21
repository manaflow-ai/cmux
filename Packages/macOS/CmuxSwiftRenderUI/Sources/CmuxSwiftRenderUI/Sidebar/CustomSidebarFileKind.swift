import Foundation

/// File format used by a custom sidebar source file.
public enum CustomSidebarFileKind: String, Sendable {
    /// Runtime SwiftUI-style interpreted sidebar source.
    case swift

    /// HTML document rendered in a native sidebar web view.
    case html

    /// Declarative JSON sidebar document.
    case json
}
