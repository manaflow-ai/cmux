/// Where a page's script FIFO (``PageScriptPipeline``) runs its scripts: the bridge of the engine
/// that shows the page now. ``PageWebView`` moves it from WebKit to Chromium (and back on a
/// fallback); the pipeline is made before the view, so it holds this box, not the view.
@MainActor
final class PageScriptTarget {
    var bridge: any PageHostBridge

    init(_ bridge: any PageHostBridge) {
        self.bridge = bridge
    }

    func evaluate(_ script: String) {
        bridge.evaluate(script)
    }
}
