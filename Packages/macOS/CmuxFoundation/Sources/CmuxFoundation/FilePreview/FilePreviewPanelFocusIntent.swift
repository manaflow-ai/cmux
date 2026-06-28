/// Which region of the file-preview panel keyboard focus should target.
public enum FilePreviewPanelFocusIntent: Hashable {
    case textEditor
    case pdfCanvas
    case pdfThumbnails
    case pdfOutline
    case imageCanvas
    case mediaPlayer
    case quickLook
}
