/// A semantic focus target inside a terminal ``Panel``.
public enum TerminalPanelFocusIntent: Equatable {
    case surface
    case findField
    case textBoxInput
}

/// A semantic focus target inside a browser ``Panel``.
public enum BrowserPanelFocusIntent: Equatable {
    case webView
    case addressBar
    case findField
}

/// A semantic focus target inside a file-preview ``Panel``.
public enum FilePreviewPanelFocusIntent: Hashable {
    case textEditor
    case pdfCanvas
    case pdfThumbnails
    case pdfOutline
    case imageCanvas
    case mediaPlayer
    case quickLook
}

/// A semantic focus target inside a project ``Panel``.
public enum ProjectPanelFocusIntent: Hashable {
    case navigator
    case detail
}

/// The panel-local focus target captured or restored across panel activations.
///
/// The `.panel` case is the whole-panel default; the per-kind cases carry the
/// specific sub-control (terminal surface, browser web view, etc.) a panel
/// owns.
public enum PanelFocusIntent: Equatable {
    case panel
    case terminal(TerminalPanelFocusIntent)
    case browser(BrowserPanelFocusIntent)
    case filePreview(FilePreviewPanelFocusIntent)
    case project(ProjectPanelFocusIntent)
}
