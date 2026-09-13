import AppKit

/// A sidebar-only drag. The destination also verifies the native source outline;
/// serialized row IDs are not capabilities to mutate sessions or other windows.
final class CloudSidebarDragItem: NSPasteboardItem {
    static let type = NSPasteboard.PasteboardType("com.cmux.cloud-sidebar-row")

    init(nodeID: String) {
        super.init()
        setString(nodeID, forType: Self.type)
    }

    @available(*, unavailable)
    required init(pasteboardPropertyList: Any, ofType: NSPasteboard.PasteboardType) {
        fatalError("init(pasteboardPropertyList:ofType:) is not supported")
    }
}
