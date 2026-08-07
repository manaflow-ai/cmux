import Foundation
import UniformTypeIdentifiers

/// Internal workspace-sidebar drag payload for reordering and cross-window moves.
struct SidebarTabDragPayload {
    static let typeIdentifier = "com.cmux.sidebar-tab-reorder"
    static let dropContentType = UTType(exportedAs: typeIdentifier)
    static let dropContentTypes: [UTType] = [dropContentType]
    static let prefix = "cmux.sidebar-tab."

    let tabId: UUID

    /// Recovers the dragged workspace id from a drag pasteboard string. The
    /// pasteboard is the one identity that survives for the whole native drag
    /// session, so drop paths can resolve a same-process source even if the
    /// destination's transient presentation was rebuilt mid-flight.
    static func workspaceId(fromPasteboardString raw: String?) -> UUID? {
        guard let raw, raw.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(raw.dropFirst(prefix.count)))
    }
}
