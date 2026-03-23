import Foundation
import WebKit

/// Pre-warms WKWebViews with Monaco Editor loaded, ready for instant use.
/// Call `MonacoWebViewPool.shared.warmUp()` at app startup.
/// When creating an EditorPanel, call `take()` to get a ready WebView.
@MainActor
final class MonacoWebViewPool {
    static let shared = MonacoWebViewPool()

    private var available: [(webView: WKWebView, handler: EditorMessageHandler)] = []
    private var warming: Int = 0
    private let poolSize = 2

    private init() {}

    /// Start pre-warming WebViews. Call once at app startup.
    func warmUp() {
        refill()
    }

    /// Take a pre-warmed WebView + handler pair. Returns nil if none ready (caller should create fresh).
    /// After taking, the pool refills in the background.
    func take() -> (webView: WKWebView, handler: EditorMessageHandler)? {
        guard !available.isEmpty else { return nil }
        let item = available.removeFirst()
        refill()
        return item
    }

    /// How many are ready right now.
    var readyCount: Int { available.count }

    private func refill() {
        let needed = poolSize - available.count - warming
        for _ in 0..<needed {
            createWarmedWebView()
        }
    }

    private func createWarmedWebView() {
        warming += 1

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let handler = EditorMessageHandler()
        config.userContentController.add(handler, name: "cmuxEditor")

        let webView = CmuxWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        // Pre-set background color to match theme
        let bgColor = GhosttyBackgroundTheme.currentColor()
        webView.layer?.backgroundColor = bgColor.cgColor

        // Load the editor HTML
        guard let editorURL = Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "editor"
        ) else {
            warming -= 1
            return
        }
        let editorDir = editorURL.deletingLastPathComponent()

        let delegate = PoolWarmUpDelegate { [weak self] in
            guard let self else { return }
            self.warming -= 1
            // Inject Monaco paths to start loading Monaco
            self.injectMonacoPaths(into: webView)
        }
        // Keep delegate alive
        objc_setAssociatedObject(webView, &PoolWarmUpDelegate.associatedKey, delegate, .OBJC_ASSOCIATION_RETAIN)
        webView.navigationDelegate = delegate
        webView.loadFileURL(editorURL, allowingReadAccessTo: editorDir)

        // When Monaco signals ready, add to available pool
        handler.onEditorReady = { [weak self, weak webView] in
            guard let self, let webView else { return }
            // Clear the warmup delegate
            objc_setAssociatedObject(webView, &PoolWarmUpDelegate.associatedKey, nil, .OBJC_ASSOCIATION_RETAIN)
            webView.navigationDelegate = nil
            handler.onEditorReady = nil
            self.available.append((webView: webView, handler: handler))
        }
    }

    private func injectMonacoPaths(into webView: WKWebView) {
        let v = MonacoCache.monacoVersion
        let vsPath = "https://cdn.jsdelivr.net/npm/monaco-editor@\(v)/min/vs"
        let cssHref = "https://cdn.jsdelivr.net/npm/monaco-editor@\(v)/min/vs/editor/editor.main.css"

        // Also inject theme colors
        let bgColor = GhosttyBackgroundTheme.currentColor()
        let isDark = bgColor.perceivedBrightness < 0.5
        let editorBg = isDark
            ? bgColor.adjustBrightness(by: 0.03).hexString()
            : bgColor.adjustBrightness(by: -0.02).hexString()

        let js = """
        document.documentElement.style.setProperty('--editor-bg', '\(editorBg)');
        document.body.style.background = '\(editorBg)';
        window.cmux.initMonaco('\(vsPath)', '\(cssHref)');
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

/// Navigation delegate that fires a callback when the page finishes loading.
private final class PoolWarmUpDelegate: NSObject, WKNavigationDelegate {
    static var associatedKey: UInt8 = 0
    let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish()
    }
}
