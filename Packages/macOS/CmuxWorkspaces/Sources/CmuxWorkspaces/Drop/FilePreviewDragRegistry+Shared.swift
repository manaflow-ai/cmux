/// Process-wide composition of the file-preview drag registry.
extension FilePreviewDragRegistry {
    /// Process-wide file-preview drag registry, shared by the file-preview
    /// pasteboard writer and every pane drop target.
    ///
    /// The registry type itself is de-singletonized (plain ``init()``, injectable
    /// for tests); this single process-wide instance exists because the drag
    /// producer (``FilePreviewDragPasteboardWriter``) and the scattered AppKit
    /// drop targets have no common constructor to inject one through.
    public static let shared = FilePreviewDragRegistry()
}
