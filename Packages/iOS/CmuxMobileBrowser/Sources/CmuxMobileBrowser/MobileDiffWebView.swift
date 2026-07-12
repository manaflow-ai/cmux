#if canImport(UIKit)
public import SwiftUI
import UIKit
public import WebKit
import CmuxMobileShellModel
import CmuxMobileSupport

/// Hosts the existing cmux React/Pierre diff renderer with a native file bridge.
public struct MobileDiffWebView: UIViewRepresentable {
    public let state: MobileDiffState

    public init(state: MobileDiffState) {
        self.state = state
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(context.coordinator.patchHandler, forURLScheme: MobileDiffPatchSchemeHandler.scheme)
        configuration.userContentController.add(context.coordinator, name: Coordinator.messageHandlerName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.attach(webView)
        return webView
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.apply(state: state)
    }

    public static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageHandlerName)
        webView.navigationDelegate = nil
        coordinator.detach()
    }

    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageHandlerName = "cmuxMobileDiff"
        let patchHandler = MobileDiffPatchSchemeHandler()
        private let state: MobileDiffState
        private weak var webView: WKWebView?
        private var loadedGeneration = -1
        private var appliedSelection: String?

        init(state: MobileDiffState) {
            self.state = state
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            apply(state: state)
        }

        func detach() {
            webView = nil
        }

        func apply(state: MobileDiffState) {
            guard let webView else { return }
            if loadedGeneration != state.generation, let document = state.document {
                do {
                    let html = try Self.viewerHTML(document: document, generation: state.generation)
                    guard MobileDiffPatchSchemeHandler.assetsAvailable else {
                        state.fail(message: L10n.string("mobile.diff.assetsMissing", defaultValue: "Diff viewer assets are missing from this build."))
                        return
                    }
                    patchHandler.configure(html: Data(html.utf8), patch: Data(document.patch.utf8))
                    loadedGeneration = state.generation
                    appliedSelection = nil
                    let url = URL(string: "\(MobileDiffPatchSchemeHandler.scheme)://viewer/index-\(state.generation).html")!
                    webView.load(URLRequest(url: url))
                } catch {
                    state.fail(message: error.localizedDescription)
                }
            }
            if appliedSelection != state.selectedFileID, let selectedFileID = state.selectedFileID {
                appliedSelection = selectedFileID
                let literal = Self.javaScriptLiteral(selectedFileID)
                webView.evaluateJavaScript("window.__cmuxMobileDiff?.selectFile(\(literal))")
            }
        }

        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.messageHandlerName,
                  let body = message.body as? [String: Any],
                  body["type"] as? String == "files",
                  let rawFiles = body["files"] else { return }
            do {
                let data = try JSONSerialization.data(withJSONObject: rawFiles)
                let files = try JSONDecoder().decode([MobileDiffFile].self, from: data)
                state.updateFiles(files, selectedFileID: body["selectedItemId"] as? String)
            } catch {
                state.fail(message: error.localizedDescription)
            }
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            apply(state: state)
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            state.fail(message: error.localizedDescription)
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            state.fail(message: error.localizedDescription)
        }

        private static func viewerHTML(document: MobileDiffDocument, generation: Int) throws -> String {
            let payload: [String: Any] = [
                "patchURL": "\(MobileDiffPatchSchemeHandler.scheme)://viewer/patch/current-\(generation).diff",
                "title": document.title,
                "sourceLabel": L10n.string("mobile.diff.workingTree", defaultValue: "Git working tree"),
                "layout": "unified",
                "layoutSource": "explicit",
                "repoRoot": document.repositoryRoot,
                "mobileNativeChrome": true,
                "labels": [
                    "diffViewer": L10n.string("mobile.diff.title", defaultValue: "Diff Viewer"),
                    "loadingDiff": L10n.string("mobile.diff.loading", defaultValue: "Loading changes…"),
                    "parsingDiff": L10n.string("mobile.diff.parsing", defaultValue: "Parsing changes…"),
                    "renderingDiff": L10n.string("mobile.diff.rendering", defaultValue: "Rendering changes…"),
                    "renderFailed": L10n.string("mobile.diff.renderFailed", defaultValue: "Couldn’t render this diff."),
                    "noFileDiffs": L10n.string("mobile.diff.empty", defaultValue: "No changed files."),
                    "untitled": L10n.string("mobile.diff.untitled", defaultValue: "Untitled"),
                ],
            ]
            let config: [String: Any] = [
                "payload": payload,
                "assets": [
                    "diffsModuleURL": "./diff-viewer/diffs.mjs",
                    "treesModuleURL": "./diff-viewer/trees.mjs",
                    "workerPoolModuleURL": "./diff-viewer/worker-pool/worker-pool.mjs",
                    "workerModuleURL": "./diff-viewer/worker-pool/worker-portable.js",
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: config)
            let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
            return """
            <!doctype html>
            <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
            <body><script id="cmux-diff-viewer-config" type="application/json">\(json)</script><div id="root"></div><script type="module" src="./webviews-app/main.mjs"></script></body></html>
            """
        }

        private static func javaScriptLiteral(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let array = String(data: data, encoding: .utf8) else { return "\"\"" }
            return String(array.dropFirst().dropLast())
        }
    }
}

final class MobileDiffPatchSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    static let scheme = "cmux-mobile-diff-data"
    static var assetsAvailable: Bool {
        guard let resourceURL = Bundle.main.resourceURL else { return false }
        return FileManager.default.fileExists(atPath: resourceURL.appendingPathComponent("webviews-app/main.mjs").path)
            && FileManager.default.fileExists(atPath: resourceURL.appendingPathComponent("diff-viewer/diffs.mjs").path)
    }

    private let lock = NSLock()
    private var html = Data()
    private var patch = Data()

    func configure(html: Data, patch: Data) {
        lock.lock()
        self.html = html
        self.patch = patch
        lock.unlock()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.host == "viewer",
              let content = content(for: url.path) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "\(content.mimeType); charset=utf-8",
                "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff",
                "Cross-Origin-Resource-Policy": "same-origin",
            ]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(content.data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func content(for requestPath: String) -> (data: Data, mimeType: String)? {
        let path = requestPath.drop(while: { $0 == "/" })
        if path.hasPrefix("index-") && path.hasSuffix(".html") {
            return (snapshot(\.html), "text/html")
        }
        if path.hasPrefix("patch/") && path.hasSuffix(".diff") {
            return (snapshot(\.patch), "text/x-diff")
        }
        guard path.hasPrefix("webviews-app/") || path.hasPrefix("diff-viewer/"),
              path.hasSuffix(".mjs") || path.hasSuffix(".js"),
              let resourceRoot = Bundle.main.resourceURL?.standardizedFileURL else { return nil }
        let fileURL = resourceRoot.appendingPathComponent(String(path)).standardizedFileURL
        guard fileURL.path.hasPrefix(resourceRoot.path + "/"),
              let data = try? Data(contentsOf: fileURL) else { return nil }
        return (data, "text/javascript")
    }

    private func snapshot(_ keyPath: KeyPath<MobileDiffPatchSchemeHandler, Data>) -> Data {
        lock.lock()
        defer { lock.unlock() }
        return self[keyPath: keyPath]
    }
}
#endif
