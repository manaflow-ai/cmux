#if os(iOS)
import CmuxMobileSupport
import Foundation
@preconcurrency import OSLog
import WebKit

/// Owns the WebKit scheme and message-handler seams for one viewer instance.
@MainActor
final class MobileDiffWebViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let schemeHandler: MobileDiffURLSchemeHandler
    private let controller: MobileDiffWebViewController

    init(
        controller: MobileDiffWebViewController,
        service: MobileDiffRPCService,
        files: [MobileDiffFileChange],
        layout: MobileDiffHostPage.Layout,
        title: String,
        onTooLargePaths: @escaping ([String]) -> Void,
        onPartialFailure: @escaping () -> Void
    ) {
        self.controller = controller
        schemeHandler = MobileDiffURLSchemeHandler(
            service: service,
            files: files,
            layout: layout,
            title: title,
            labels: Self.webLabels,
            onTooLargePaths: onTooLargePaths,
            onPartialFailure: onPartialFailure
        )
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "cmuxMobileDiff",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            controller.didBecomeReady()
        case "stats":
            controller.didReceiveStats(total: (body["files"] as? [Any])?.count)
        case "currentFile":
            guard let path = body["path"] as? String,
                  let index = Self.integer(body["index"]),
                  let total = Self.integer(body["total"]) else { return }
            controller.didChangeCurrentFile(path: path, index: index, total: total)
        case "error":
            let message = (body["message"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Logger(subsystem: "com.cmuxterm.app", category: "DiffViewerWeb")
                .error("web renderer error: \(message ?? "<empty>", privacy: .public)")
            controller.showError(message.flatMap { $0.isEmpty ? nil : $0 } ?? Self.renderError)
        default:
            break
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        presentNavigationError(error)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        presentNavigationError(error)
    }

    func tearDown(webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "cmuxMobileDiff")
        webView.navigationDelegate = nil
        schemeHandler.cancelAll()
        controller.detach(webView)
    }

    private func presentNavigationError(_ error: any Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        controller.showError(Self.renderError)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private static var renderError: String {
        L10n.string(
            "mobile.diff.error.render",
            defaultValue: "The diff could not be displayed."
        )
    }

    private static var webLabels: [String: String] {
        [
            "diffViewer": L10n.string("mobile.diff.web.diffViewer", defaultValue: "Diff viewer"),
            "loadingDiff": L10n.string("mobile.diff.web.loading", defaultValue: "Loading diff…"),
            "loadingRenderer": L10n.string("mobile.diff.web.loadingRenderer", defaultValue: "Loading renderer…"),
            "noFileDiffs": L10n.string("mobile.diff.web.noFileDiffs", defaultValue: "No file diffs found."),
            "parsingDiff": L10n.string("mobile.diff.web.parsing", defaultValue: "Parsing diff…"),
            "renderFailed": renderError,
            "renderingDiff": L10n.string("mobile.diff.web.rendering", defaultValue: "Rendering diff…"),
            "untitled": L10n.string("mobile.diff.web.untitled", defaultValue: "Untitled"),
        ]
    }
}
#endif
