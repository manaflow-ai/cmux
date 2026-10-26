/// Where a page's script FIFO (``PageScriptPipeline``) runs its scripts: the bridge of the engine
/// that shows the page now. ``PageWebView`` sets it to WebKit's or Chromium's (and to WebKit's on a
/// fallback); the pipeline is made before the view, so it holds this box, not the view.
@MainActor
final class PageScriptTarget {
    /// Nil while no engine shows a document: a Chromium page on its way has none, and it gets its
    /// theme and scale when it attaches (``PageWebView/startChromium(hosting:)``).
    var bridge: (any PageHostBridge)?
    /// False while the page waits for its first show (PageWebView+FirstShow.swift): it has no
    /// document, and a script would make WebKit launch its WebContent process
    /// (`WebPageProxy::runJavaScriptInFrameInScriptWorld` calls `launchInitialProcessIfNecessary`).
    /// Its scripts are dropped: no page code subscribes before a document runs, and the first
    /// document gets its theme and scale from its document-start scripts and `documentFinished()`.
    var hasDocument: Bool

    init(_ bridge: (any PageHostBridge)? = nil, hasDocument: Bool = true) {
        self.bridge = bridge
        self.hasDocument = hasDocument
    }

    func evaluate(_ script: String) {
        guard hasDocument else { return }
        bridge?.evaluate(script)
    }
}
