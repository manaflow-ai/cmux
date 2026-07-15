import AppKit

/// Drag writer for note rows: the tree's move type composed with the Files
/// tab's file-preview writer (drag registry + bonsplit tab-transfer payload
/// + fileURL). Dropping on a terminal inserts the shell-escaped path or
/// opens the preview per the file-drop setting with Shift toggling the
/// alternate, exactly like a Files-tab drag; dragging out exports the file.
/// In-sidebar moves still work because the window file-drop overlay defers
/// to the tree's region (SidebarFileDropDeferralRegistry).
final class NotesTreeNoteDragWriter: NSObject, NSPasteboardWriting {
    private let movePath: String
    private let preview: FilePreviewDragPasteboardWriter

    init(filePath: String, displayTitle: String) {
        self.movePath = filePath
        self.preview = FilePreviewDragPasteboardWriter(filePath: filePath, displayTitle: displayTitle)
        super.init()
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [NotesTreePanelView.movePasteboardType] + preview.writableTypes(for: pasteboard)
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == NotesTreePanelView.movePasteboardType { return movePath }
        return preview.pasteboardPropertyList(forType: type)
    }
}
