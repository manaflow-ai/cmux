#if canImport(UIKit)
import CmuxMobileShellModel
import CmuxMobileSupport
public import Foundation
public import WebKit

/// Coordinates native selection state, WebKit navigation, and renderer messages.
@MainActor
public final class MobileDiffWebViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let messageHandlerName = "cmuxMobileDiff"
    let patchHandler = MobileDiffPatchSchemeHandler()
    private let state: MobileDiffState
    private weak var webView: WKWebView?
    private var loadedGeneration = -1
    private var pendingGeneration: Int?
    private var appliedSelection: String?
    private var loadTask: Task<Void, Never>?
    private var renderTimeoutTask: Task<Void, Never>?

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
        renderTimeoutTask?.cancel()
        renderTimeoutTask = nil
        webView = nil
    }

    func apply(state: MobileDiffState) {
        guard let webView else { return }
        if loadedGeneration != state.generation,
           pendingGeneration != state.generation,
           let document = state.document {
            do {
                let html = try mobileDiffViewerHTML(document: document, generation: state.generation)
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
                        if pendingGeneration == generation { pendingGeneration = nil }
                        return
                    }
                    loadedGeneration = generation
                    pendingGeneration = nil
                    appliedSelection = nil
                    let url = URL(string: "\(MobileDiffPatchSchemeHandler.scheme)://viewer/index-\(generation).html")!
                    webView.load(URLRequest(url: url))
                    startRenderTimeout(generation: generation)
                }
            } catch {
                state.fail(message: error.localizedDescription)
            }
        }
        if appliedSelection != state.selectedFileID, let selectedFileID = state.selectedFileID {
            let literal = mobileDiffJavaScriptLiteral(selectedFileID)
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

    /// Applies a generation-scoped file or selection message from the renderer.
    /// - Parameters:
    ///   - userContentController: The controller that received the renderer message.
    ///   - message: The generation-tagged mobile diff message.
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageHandlerName,
              let body = message.body as? [String: Any],
              let generation = body["generation"] as? Int,
              generation == state.generation,
              let type = body["type"] as? String else { return }
        if type == "ready" {
            renderTimeoutTask?.cancel()
            renderTimeoutTask = nil
            return
        }
        if type == "error" {
            renderTimeoutTask?.cancel()
            renderTimeoutTask = nil
            state.fail(message: L10n.string("mobile.diff.renderFailed", defaultValue: "Couldn’t render this diff."))
            return
        }
        if type == "selection" {
            if let selectedFileID = body["selectedItemId"] as? String {
                state.selectFile(id: selectedFileID)
            }
            return
        }
        guard type == "files", let rawFiles = body["files"] else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: rawFiles)
            let files = try JSONDecoder().decode([MobileDiffFile].self, from: data)
            state.updateFiles(files, selectedFileID: body["selectedItemId"] as? String)
        } catch {
            state.fail(message: error.localizedDescription)
        }
    }

    /// Reapplies native state after a renderer navigation finishes.
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        apply(state: state)
    }

    /// Surfaces a committed-navigation failure in native diff state.
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failNavigation(with: error)
    }

    /// Surfaces a provisional-navigation failure in native diff state.
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failNavigation(with: error)
    }

    private func failNavigation(with error: any Error) {
        let nsError = error as NSError
        guard nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled else { return }
        renderTimeoutTask?.cancel()
        renderTimeoutTask = nil
        state.fail(message: error.localizedDescription)
    }

    private func startRenderTimeout(generation: Int) {
        renderTimeoutTask?.cancel()
        renderTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .seconds(15))
            } catch {
                return
            }
            guard let self, state.generation == generation else { return }
            renderTimeoutTask = nil
            state.fail(message: L10n.string("mobile.diff.renderFailed", defaultValue: "Couldn’t render this diff."))
        }
    }
}

// lint:allow File-scope pure helper required by the cmux package-design policy.
private func mobileDiffViewerHTML(document: MobileDiffDocument, generation: Int) throws -> String {
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

// lint:allow File-scope pure helper required by the cmux package-design policy.
private func mobileDiffJavaScriptLiteral(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
          let array = String(data: data, encoding: .utf8) else { return "\"\"" }
    return String(array.dropFirst().dropLast())
}
#endif
