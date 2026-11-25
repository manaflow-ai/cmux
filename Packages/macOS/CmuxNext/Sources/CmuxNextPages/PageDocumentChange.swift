/// Why a page's document is about to change or is gone (``PageWebView/onDocumentWillChange``).
public enum PageDocumentChange: String, Sendable {
    /// A reload was asked for (the host, app health's `reloadPage`, a live web override, a crash retry); the old
    /// document still draws until the new one commits.
    case reload
    /// The renderer ended (WebKit's web content process, Chromium's renderer or browser): nothing draws now.
    case contentEnded = "content-ended"
    /// App health ended the renderer to repair the page (`restartRenderer`); it loads again by itself.
    case rendererRestart = "renderer-restart"
    /// A new main-frame document committed (either engine): it has not painted yet.
    case committed
}
