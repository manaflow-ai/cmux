#if canImport(UIKit)
import CmuxAgentChat
import SwiftUI
import UIKit
import WebKit

/// Renders document markdown with the shared cmux markdown-viewer web shell —
/// the same marked.js + highlight.js + GitHub CSS pipeline as the macOS
/// markdown panel, so both platforms produce identical documents.
///
/// iOS deviations from the macOS coordinator: there is no backing file on the
/// phone, so `.md` link resolution answers "missing" (links degrade to inert
/// text) and local relative images stay unresolved. Remote images keep the
/// consent-gated HTTPS-only loader. Activated links leave through the system
/// opener.
struct MarkdownWebContentView: UIViewRepresentable {
    let markdown: String
    let theme: MarkdownWebTheme
    /// Body zoom factor derived from the reader's Dynamic Type size.
    let pageZoom: CGFloat
    let openURL: OpenURLAction

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        config.userContentController.add(
            MarkdownWebWeakScriptMessageHandler(context.coordinator),
            name: "cmuxLib"
        )
        config.setURLSchemeHandler(context.coordinator, forURLScheme: MarkdownWebViewerScheme.localImage)
        config.setURLSchemeHandler(context.coordinator, forURLScheme: MarkdownWebViewerScheme.remoteImage)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
#if DEBUG
        webView.isInspectable = true
#endif
        webView.overrideUserInterfaceStyle = theme.isDark ? .dark : .light

        context.coordinator.webView = webView
        context.coordinator.openURL = openURL
        context.coordinator.setPageZoom(pageZoom)
        context.coordinator.loadShell(theme: theme, initialMarkdown: markdown)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.openURL = openURL
        webView.overrideUserInterfaceStyle = theme.isDark ? .dark : .light
        context.coordinator.setPageZoom(pageZoom)
        context.coordinator.update(markdown: markdown, theme: theme)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency WKNavigationDelegate, @preconcurrency WKUIDelegate,
        @preconcurrency WKScriptMessageHandler, @preconcurrency WKURLSchemeHandler {
        weak var webView: WKWebView?
        var openURL: OpenURLAction?

        private var pendingMarkdown: String = ""
        private var pendingTheme: MarkdownWebTheme = .resolve(isDark: false)
        private var lastMarkdown: String?
        private var lastTheme: MarkdownWebTheme?
        private var lastPageZoom: CGFloat = 1
        private var isLoaded = false
        private var isShellLoading = false
        private var webContentProcessRecoveryAttempts = 0
        private let maxWebContentProcessRecoveryAttempts = 2
        private var requestedLibs: Set<String> = []

        private final class ImageLoad {
            var reader: Task<MarkdownRemoteImageFetchResult?, Never>?
            var sender: Task<Void, Never>?

            func cancel() {
                reader?.cancel()
                sender?.cancel()
            }
        }
        private var imageLoads: [ObjectIdentifier: ImageLoad] = [:]

        func close() {
            if let webView {
                webView.stopLoading()
                webView.configuration.userContentController.removeScriptMessageHandler(forName: "cmuxLib")
                webView.navigationDelegate = nil
                webView.uiDelegate = nil
            }
            webView = nil
            isLoaded = false
            isShellLoading = false
            webContentProcessRecoveryAttempts = 0
            requestedLibs.removeAll()
            cancelImageLoads()
        }

        func loadShell(theme: MarkdownWebTheme, initialMarkdown: String) {
            pendingMarkdown = initialMarkdown
            pendingTheme = theme
            lastTheme = theme
            requestedLibs.removeAll()
            isLoaded = false
            guard let html = MarkdownWebViewerAssets.shared.shellHTML() else {
                isShellLoading = false
                return
            }
            isShellLoading = true
            webView?.loadHTMLString(html, baseURL: nil)
        }

        func update(markdown: String, theme: MarkdownWebTheme) {
            let themeChanged = lastTheme != theme
            let contentChanged = lastMarkdown != markdown
            let shellNeedsReload = !isLoaded && !isShellLoading
            guard themeChanged || contentChanged || shellNeedsReload else { return }

            pendingMarkdown = markdown
            pendingTheme = theme

            if themeChanged {
                lastTheme = theme
                if isLoaded {
                    applyTheme(theme)
                    if !contentChanged {
                        pushMarkdown(lastMarkdown ?? pendingMarkdown)
                    }
                }
            }

            if contentChanged {
                webContentProcessRecoveryAttempts = 0
                lastMarkdown = markdown
                if isLoaded {
                    pushMarkdown(markdown)
                } else if shellNeedsReload {
                    loadShell(theme: theme, initialMarkdown: markdown)
                }
            } else if shellNeedsReload {
                if webContentProcessRecoveryAttempts < maxWebContentProcessRecoveryAttempts {
                    loadShell(theme: theme, initialMarkdown: markdown)
                }
            }
        }

        func setPageZoom(_ zoom: CGFloat) {
            lastPageZoom = zoom
            applyPageZoom()
        }

        private func applyPageZoom(forceShellSync: Bool = false) {
            guard let webView else { return }
            let zoom = lastPageZoom
            let shouldSyncShell = forceShellSync || abs(webView.pageZoom - zoom) > 0.0001
            if abs(webView.pageZoom - zoom) > 0.0001 { webView.pageZoom = zoom }
            if shouldSyncShell {
                webView.evaluateJavaScript(
                    "window.__cmuxSetMarkdownZoom && window.__cmuxSetMarkdownZoom(\(Double(zoom)), \(Double(webView.bounds.width)));",
                    completionHandler: nil
                )
            }
        }

        private func applyTheme(_ theme: MarkdownWebTheme) {
            guard let webView else { return }
            let payload = [
                "--bgColor-default": theme.background,
                "--bgColor-muted": theme.mutedBackground,
                "--bgColor-neutral-muted": theme.neutralMutedBackground,
                "--borderColor-default": theme.border,
                "--borderColor-muted": theme.mutedBorder,
                "--borderColor-neutral-muted": theme.mutedBorder
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            let js = """
            (function(vars) {
              var content = document.getElementById('content');
              if (!content) { return; }
              Object.keys(vars).forEach(function(name) {
                content.style.setProperty(name, vars[name]);
              });
              content.style.background = 'transparent';
              if (window.__cmuxApplyTheme) { window.__cmuxApplyTheme(); }
            })(\(json));
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        private func pushMarkdown(_ markdown: String) {
            guard let webView else { return }
            guard let js = Self.renderMarkdownScript(markdown) else { return }
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        private static func renderMarkdownScript(_ markdown: String) -> String? {
            let failureMessage = String(
                localized: "markdown.web.rendererInitFailed",
                defaultValue: "Markdown renderer failed to initialize. Showing raw source.",
                bundle: .module
            )
            guard let data = try? JSONSerialization.data(withJSONObject: [markdown, failureMessage]),
                  let arrayLiteral = String(data: data, encoding: .utf8) else { return nil }
            return """
            (function(args) {
              var md = args[0];
              if (window.__cmuxRenderMarkdown) {
                window.__cmuxRenderMarkdown(md);
                return;
              }
              var el = document.getElementById('content') || document.body;
              function esc(s) {
                var div = document.createElement('div');
                div.textContent = String(s == null ? '' : s);
                return div.innerHTML;
              }
              el.innerHTML = '<pre style=\"color:#f85149;white-space:pre-wrap\">' + esc(args[1]) + '\\n\\n' + esc(md) + '</pre>';
            })(\(arrayLiteral));
            """
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "cmuxLib",
                  let body = message.body as? [String: Any] else { return }
            if let lib = body["lib"] as? String {
                handleLibRequest(lib)
                return
            }
            guard let action = body["action"] as? String else { return }
            switch action {
            case "resolveMarkdownFile":
                // No backing file system on the phone: answer "missing" so
                // `.md`-looking links stay inert instead of navigating.
                guard let requestId = body["requestId"] as? String,
                      let webView else { return }
                let payload: [String: Any] = ["requestId": requestId, "exists": false, "path": ""]
                guard let data = try? JSONSerialization.data(withJSONObject: payload),
                      let json = String(data: data, encoding: .utf8) else { return }
                webView.evaluateJavaScript(
                    "window.__cmuxMarkdownFileResolved && window.__cmuxMarkdownFileResolved(\(json));",
                    completionHandler: nil
                )
            default:
                break
            }
        }

        private func handleLibRequest(_ lib: String) {
            if requestedLibs.contains(lib) { return }
            requestedLibs.insert(lib)

            let specs: [(name: String, ext: String)]
            switch lib {
            case "mermaid":
                specs = [("mermaid.min", "js")]
            case "vega-lite":
                specs = [("vega.min", "js"), ("vega-lite.min", "js"), ("vega-embed.min", "js")]
            default:
                return
            }

            // The diagram bundles are megabytes; read and inflate them off the
            // main actor, then inject on main.
            Task { [weak self] in
                guard let sources = await MarkdownWebViewerAssets.shared.assets(specs),
                      sources.contains(where: { !$0.isEmpty }) else {
                    self?.requestedLibs.remove(lib)
                    return
                }
                guard let self, let webView = self.webView else { return }

                var injection = ""
                for src in sources where !src.isEmpty {
                    injection += src
                    injection += "\n;"
                }
                let libLiteral = (try? JSONSerialization.data(withJSONObject: [lib]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
                let suffix = "\nwindow.__cmuxLibLoaded && window.__cmuxLibLoaded(\(libLiteral)[0]);"
                webView.evaluateJavaScript(injection + suffix) { [weak self] _, error in
                    if error != nil {
                        Task { @MainActor [weak self] in
                            self?.requestedLibs.remove(lib)
                        }
                    }
                }
            }
        }

        // MARK: WKURLSchemeHandler

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let requestURL = urlSchemeTask.request.url else {
                urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
                return
            }

            let taskId = ObjectIdentifier(urlSchemeTask as AnyObject)
            let load = ImageLoad()
            imageLoads[taskId] = load

            let reader: Task<MarkdownRemoteImageFetchResult?, Never>
            if requestURL.scheme?.lowercased() == MarkdownWebViewerScheme.remoteImage,
               let remoteURL = MarkdownRemoteImageSecurity.remoteImageURL(from: requestURL) {
                reader = Task.detached(priority: .userInitiated) {
                    await MarkdownRemoteImageFetcher.fetch(remoteURL)
                }
            } else {
                // Local images cannot resolve on the phone — the document's
                // files live on the Mac. Serve empty bytes so the shell's
                // placeholder handling keeps the layout stable.
                reader = Task { nil }
            }
            load.reader = reader

            let sender = Task { [weak self, weak load] in
                defer {
                    if let load, self?.imageLoads[taskId] === load {
                        self?.imageLoads[taskId] = nil
                    }
                }
                let result = await reader.value
                guard !Task.isCancelled else { return }
                let data = result?.data ?? Data()
                let response = URLResponse(
                    url: requestURL,
                    mimeType: result?.mimeType ?? "image/png",
                    expectedContentLength: data.count,
                    textEncodingName: nil
                )
                urlSchemeTask.didReceive(response)
                if !data.isEmpty {
                    urlSchemeTask.didReceive(data)
                }
                urlSchemeTask.didFinish()
            }
            load.sender = sender
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
            let taskId = ObjectIdentifier(urlSchemeTask as AnyObject)
            guard let load = imageLoads.removeValue(forKey: taskId) else { return }
            load.cancel()
        }

        private func cancelImageLoads() {
            let loads = imageLoads.values
            imageLoads.removeAll()
            for load in loads {
                load.cancel()
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isShellLoading = false
            isLoaded = true
            applyPageZoom(forceShellSync: true)
            applyTheme(lastTheme ?? pendingTheme)
            let md = lastMarkdown ?? pendingMarkdown
            lastMarkdown = md
            pushMarkdown(md)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleShellNavigationFailure()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            handleShellNavigationFailure()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let currentWebView = self.webView, currentWebView === webView else { return }
            isShellLoading = false
            guard webContentProcessRecoveryAttempts < maxWebContentProcessRecoveryAttempts else {
                isLoaded = false
                requestedLibs.removeAll()
                return
            }
            webContentProcessRecoveryAttempts += 1
            loadShell(
                theme: lastTheme ?? pendingTheme,
                initialMarkdown: lastMarkdown ?? pendingMarkdown
            )
        }

        private func handleShellNavigationFailure() {
            guard isShellLoading else { return }
            isShellLoading = false
            isLoaded = false
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                if MarkdownWebLinkPolicy.isInPageFragment(url) {
                    decisionHandler(.allow)
                    return
                }
                if let external = MarkdownWebLinkPolicy.externalURL(for: url) {
                    openURL?(external)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url,
               let external = MarkdownWebLinkPolicy.externalURL(for: url) {
                openURL?(external)
            }
            return nil
        }
    }
}

/// Breaks the retain cycle between WKUserContentController and its message
/// handler (the controller retains handlers strongly).
private final class MarkdownWebWeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var delegate: (any WKScriptMessageHandler)?

    init(_ delegate: any WKScriptMessageHandler) {
        self.delegate = delegate
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
#endif
