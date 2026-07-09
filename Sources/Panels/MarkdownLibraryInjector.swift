import WebKit

/// Owns the markdown renderer's lazy-library injection bookkeeping: the set of
/// JS libraries (mermaid, vega-lite) already requested for a single WebView, so
/// each loads at most once per WebView lifetime. The set is reset only when the
/// shell is reloaded (`loadShell`, crash recovery, teardown); theme switches
/// reuse the already-loaded libraries.
///
/// Isolation: `@MainActor final class` rather than a value type because the
/// failure path runs in WebKit's escaping `evaluateJavaScript` completion
/// handler, which must un-record the library so a later render can retry. That
/// post-call mutation of `requestedLibs` requires reference semantics; a struct
/// could not be mutated from inside its own escaping closure. The coordinator
/// resolves the `WebView`, `MarkdownViewerAssets`, and `MarkdownRenderScript`
/// collaborators app-side and passes the live `WebView` into `inject`.
@MainActor
final class MarkdownLibraryInjector {
    private var requestedLibs: Set<String> = []

    /// Clears the per-WebView lazy-library state so a freshly (re)loaded shell
    /// re-injects libraries on demand.
    func reset() {
        requestedLibs.removeAll()
    }

    /// Injects the bundled source for `lib` into `webView`, loading each library
    /// at most once per WebView lifetime. On evaluation failure the library is
    /// un-recorded so the next render can retry.
    func inject(_ lib: String, into webView: WKWebView) {
        // Load each library at most once per WebView lifetime. State is
        // reset only when the shell is reloaded via loadShell(); theme
        // switches reuse the already-loaded libs.
        if requestedLibs.contains(lib) { return }
        requestedLibs.insert(lib)

        let assets = MarkdownViewerAssets.shared
        let sources: [String]
        switch lib {
        case "mermaid":
            sources = [assets.lazyAsset(name: "mermaid.min", ext: "js")]
        case "vega-lite":
            // Order matters: vega first, then vega-lite, then vega-embed.
            sources = [
                assets.lazyAsset(name: "vega.min", ext: "js"),
                assets.lazyAsset(name: "vega-lite.min", ext: "js"),
                assets.lazyAsset(name: "vega-embed.min", ext: "js"),
            ]
        default:
            return
        }

        let script = MarkdownRenderScript.loadLibrary(named: lib, sources: sources)
        webView.evaluateJavaScript(script.source) { [weak self] _, error in
            if let error {
                // Allow retry on next render if this attempt failed.
                self?.requestedLibs.remove(lib)
#if DEBUG
                NSLog("MarkdownPanel: failed to load \(lib): \(error)")
#endif
            }
        }
    }
}
