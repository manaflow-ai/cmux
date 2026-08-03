import Foundation

/// File format used by a custom sidebar source file.
public enum CustomSidebarFileKind: String, Sendable {
    /// Runtime interpreted sidebar source.
    case swift

    /// Declarative JSON sidebar document.
    case json
}
