/// The action a key event maps to inside the file-preview PDF surfaces.
public enum FilePreviewPDFKeyboardAction: Equatable {
    /// The key event should fall through to the standard responder chain.
    case native
    /// The key event requests page navigation by the signed delta.
    case navigatePage(Int)
}
