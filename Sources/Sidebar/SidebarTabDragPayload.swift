import AppKit
import Foundation
import UniformTypeIdentifiers

/// Internal workspace-sidebar drag payload for reordering and cross-window moves.
struct SidebarTabDragPayload {
    /// Pasteboard type identifying a sidebar tab drag. Declared in
    /// `Resources/Info.plist` under `UTExportedTypeDeclarations`.
    static let typeIdentifier = "com.cmux.sidebar-tab-reorder"
    /// SwiftUI drop-target `UTType` for the drag type above.
    static let dropContentType = UTType(exportedAs: typeIdentifier)
    /// Convenience list for `.onDrop(of:)` call sites.
    static let dropContentTypes: [UTType] = [dropContentType]
    /// String prefix preceding the workspace UUID on the pasteboard.
    static let prefix = "cmux.sidebar-tab."

    /// The dragged workspace's identity for the whole drag session.
    let tabId: UUID

    /// AppKit-native pasteboard writer for `beginDraggingSession`, matching the
    /// canonical sidebar pattern in `SidebarWorkspaceTableController`. The drop
    /// side reads this string back via `workspaceId(fromPasteboardString:)`.
    func pasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(
            "\(Self.prefix)\(tabId.uuidString)",
            forType: NSPasteboard.PasteboardType(Self.typeIdentifier)
        )
        return item
    }

    /// Recovers the dragged workspace id from a drag pasteboard string. The
    /// pasteboard is the one identity that survives for the whole native drag
    /// session, so drop paths use it to re-arm drag state that was cleared
    /// mid-flight (for example by the app-resign failsafe).
    static func workspaceId(fromPasteboardString raw: String?) -> UUID? {
        guard let raw, raw.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(raw.dropFirst(prefix.count)))
    }
}
