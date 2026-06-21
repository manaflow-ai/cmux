import SwiftUI

/// Environment flag the canvas sets over hosted panel content so browser
/// webviews use local inline hosting instead of the window-level portal.
///
/// On a scrolling canvas the window portal repositions webviews after the
/// fact, and WKWebView's out-of-process compositing makes content visibly
/// trail its pane during pans. Inline hosting parents the webview inside the
/// pane's own hierarchy, so it moves in the same CoreAnimation transaction
/// as the pane and scales with canvas magnification.
private struct CanvasInlineBrowserHostingKey: EnvironmentKey {
    static let defaultValue = false
}

/// Environment flag for split-tree surfaces that need the terminal's real
/// AppKit host inside the SwiftUI tree instead of the window-level portal.
///
/// Zoomable splits use this so magnification scales the terminal content as
/// part of the packed split tree.
private struct DirectTerminalHostingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var cmuxCanvasInlineBrowserHosting: Bool {
        get { self[CanvasInlineBrowserHostingKey.self] }
        set { self[CanvasInlineBrowserHostingKey.self] = newValue }
    }

    var cmuxDirectTerminalHosting: Bool {
        get { self[DirectTerminalHostingKey.self] }
        set { self[DirectTerminalHostingKey.self] = newValue }
    }
}
