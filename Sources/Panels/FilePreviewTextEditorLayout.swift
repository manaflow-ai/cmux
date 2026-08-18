import AppKit

/// Shared TextKit 1 layout constants for the built-in file editor.
enum FilePreviewTextEditorLayout {
    /// Insets around the editor's text container.
    static let textContainerInset = NSSize(width: 12, height: 10)
    /// Extra padding inserted at the start of each line fragment.
    static let lineFragmentPadding: CGFloat = 0
}
