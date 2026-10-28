import AppKit
import WebKit

/// The gap beside a WebKit page its pane's spring holds (`WebKitPageContainer+SpringResize`) shows the
/// document's own background, read as Chromium's is (`CEFTab+ResizeBackdrop`): the root element's, else the
/// body's, else WebKit's white; none for a translucent one. The web view's `underPageBackgroundColor` is clear
/// (`WebKitTab.init`), so it cannot give it. Read only in a pane whose pages hold their size in springs (the
/// `pageSpringResizeOnce` feature): when the container joins such a pane and when a document finishes there.
extension WebKitTab {
    /// Reads the current document's background into the container (``WebKitPageContainer/pageBackdrop``).
    func samplePageBackdrop() {
        container.pageBackdrop = nil
        guard container.springPlacement != nil, !isClosed, !PageBackground.isBlank(webView.url) else { return }
        let url = webView.url
        // cmux's own script: no user gesture (`WebKitGestureFreeEvaluation`), answered in WebKit's callback.
        WebKitGestureFreeEvaluation(webView: webView).evaluate(CEFTab.pageBackdropScript, in: .page) { [weak self] value in
            // A navigation since the read: the next document reads its own when it finishes.
            guard let self, let value, self.webView.url == url, !self.isClosed else { return }
            self.container.pageBackdrop = CEFTab.backdropARGB(from: value).map(PageBackground.cgColor(argb:))
        }
    }

    /// A new document committed: until it finishes, the page area may show what is under it, so the gap does too.
    func resetPageBackdrop() {
        container.pageBackdrop = nil
    }
}
