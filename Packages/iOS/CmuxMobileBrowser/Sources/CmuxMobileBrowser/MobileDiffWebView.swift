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
        private var pendingGeneration: Int?
        private var appliedSelection: String?
        private var loadTask: Task<Void, Never>?

        init(state: MobileDiffState) {
            self.state = state
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            apply(state: state)
        }

        func detach() {
            loadTask?.cancel()
            loadTask = nil
            webView = nil
        }

        func apply(state: MobileDiffState) {
            guard let webView else { return }
            if loadedGeneration != state.generation,
               pendingGeneration != state.generation,
               let document = state.document {
                do {
                    let html = try Self.viewerHTML(document: document, generation: state.generation)
                    guard MobileDiffPatchSchemeHandler.assetsAvailable else {
                        loadedGeneration = state.generation
                        state.fail(message: L10n.string("mobile.diff.assetsMissing", defaultValue: "Diff viewer assets are missing from this build."))
                        return
                    }
                    let generation = state.generation
                    pendingGeneration = generation
                    loadTask?.cancel()
                    loadTask = Task { @MainActor [weak self, weak webView] in
                        guard let self, let webView else { return }
                        await patchHandler.configure(
                            generation: generation,
                            html: Data(html.utf8),
                            patch: Data(document.patch.utf8)
                        )
                        guard !Task.isCancelled, state.generation == generation else {
                            if pendingGeneration == generation {
                                pendingGeneration = nil
                            }
                            return
                        }
                        loadedGeneration = generation
                        pendingGeneration = nil
                        appliedSelection = nil
                        let url = URL(string: "\(MobileDiffPatchSchemeHandler.scheme)://viewer/index-\(generation).html")!
                        webView.load(URLRequest(url: url))
                    }
                } catch {
                    state.fail(message: error.localizedDescription)
                }
            }
            if appliedSelection != state.selectedFileID, let selectedFileID = state.selectedFileID {
                let literal = Self.javaScriptLiteral(selectedFileID)
                let script = "Boolean(window.__cmuxMobileDiff && (window.__cmuxMobileDiff.selectFile(\(literal)), true))"
                webView.evaluateJavaScript(script) { [weak self] value, error in
                    Task { @MainActor in
                        guard let self,
                              error == nil,
                              value as? Bool == true,
                              state.selectedFileID == selectedFileID else { return }
                        self.appliedSelection = selectedFileID
                    }
                }
            }
        }

        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.messageHandlerName,
                  let body = message.body as? [String: Any],
                  body["type"] as? String == "files",
                  let generation = body["generation"] as? Int,
                  generation == state.generation,
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
            failNavigation(with: error)
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            failNavigation(with: error)
        }

        private func failNavigation(with error: any Error) {
            let nsError = error as NSError
            guard nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled else { return }
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
                "mobileDiffGeneration": generation,
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

    private let store = MobileDiffPatchStore()

    func configure(generation: Int, html: Data, patch: Data) async {
        await store.configure(generation: generation, html: html, patch: patch)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.host == "viewer" else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let requestID = ObjectIdentifier(urlSchemeTask as AnyObject)
        let pendingTask = MobileDiffPendingSchemeTask(urlSchemeTask)
        Task { [store] in
            guard await store.beginRequest(requestID) else { return }
            guard let content = await store.content(for: url.path) else {
                await store.failRequest(requestID, task: pendingTask, error: URLError(.badURL))
                return
            }
            await store.finishRequest(requestID, task: pendingTask, url: url, content: content)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let requestID = ObjectIdentifier(urlSchemeTask as AnyObject)
        Task { [store] in
            await store.stopRequest(requestID)
        }
    }
}

private actor MobileDiffPatchStore {
    private var payloads: [Int: MobileDiffPatchPayload] = [:]
    private var activeRequests: Set<ObjectIdentifier> = []
    private var stoppedRequests: Set<ObjectIdentifier> = []
    private var stoppedRequestOrder: [ObjectIdentifier] = []

    func configure(generation: Int, html: Data, patch: Data) {
        payloads[generation] = MobileDiffPatchPayload(html: html, patch: patch)
        for expiredGeneration in payloads.keys.sorted().dropLast(2) {
            payloads[expiredGeneration] = nil
        }
    }

    func content(for requestPath: String) -> MobileDiffPatchContent? {
        let path = requestPath.drop(while: { $0 == "/" })
        if let generation = generation(in: path, prefix: "index-", suffix: ".html"),
           let payload = payloads[generation] {
            return MobileDiffPatchContent(data: payload.html, mimeType: "text/html")
        }
        if let generation = generation(in: path, prefix: "patch/current-", suffix: ".diff"),
           let payload = payloads[generation] {
            return MobileDiffPatchContent(data: payload.patch, mimeType: "text/x-diff")
        }
        guard path.hasPrefix("webviews-app/") || path.hasPrefix("diff-viewer/"),
              path.hasSuffix(".mjs") || path.hasSuffix(".js"),
              let resourceRoot = Bundle.main.resourceURL?.standardizedFileURL else { return nil }
        let fileURL = resourceRoot.appendingPathComponent(String(path)).standardizedFileURL
        guard fileURL.path.hasPrefix(resourceRoot.path + "/"),
              let data = try? Data(contentsOf: fileURL) else { return nil }
        return MobileDiffPatchContent(data: data, mimeType: "text/javascript")
    }

    func beginRequest(_ requestID: ObjectIdentifier) -> Bool {
        guard stoppedRequests.remove(requestID) == nil else {
            stoppedRequestOrder.removeAll { $0 == requestID }
            return false
        }
        activeRequests.insert(requestID)
        return true
    }

    func stopRequest(_ requestID: ObjectIdentifier) {
        guard activeRequests.remove(requestID) == nil,
              stoppedRequests.insert(requestID).inserted else { return }
        stoppedRequestOrder.append(requestID)
        if stoppedRequestOrder.count > 64 {
            stoppedRequests.remove(stoppedRequestOrder.removeFirst())
        }
    }

    func failRequest(_ requestID: ObjectIdentifier, task: MobileDiffPendingSchemeTask, error: any Error) {
        guard activeRequests.remove(requestID) != nil else { return }
        task.fail(with: error)
    }

    func finishRequest(
        _ requestID: ObjectIdentifier,
        task: MobileDiffPendingSchemeTask,
        url: URL,
        content: MobileDiffPatchContent
    ) {
        guard activeRequests.remove(requestID) != nil else { return }
        task.finish(url: url, content: content)
    }

    private func generation(in path: Substring, prefix: String, suffix: String) -> Int? {
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        return Int(path.dropFirst(prefix.count).dropLast(suffix.count))
    }
}

private struct MobileDiffPatchPayload: Sendable {
    let html: Data
    let patch: Data
}

private struct MobileDiffPatchContent: Sendable {
    let data: Data
    let mimeType: String
}

/// WebKit owns this callback token and permits asynchronous scheme responses.
private final class MobileDiffPendingSchemeTask: @unchecked Sendable {
    private let task: any WKURLSchemeTask

    init(_ task: any WKURLSchemeTask) {
        self.task = task
    }

    func fail(with error: any Error) {
        task.didFailWithError(error)
    }

    func finish(url: URL, content: MobileDiffPatchContent) {
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
        task.didReceive(response)
        task.didReceive(content.data)
        task.didFinish()
    }
}
#endif
