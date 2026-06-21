import AppKit
import CmuxSwiftRender
import SwiftUI
import WebKit

/// Owns WebKit lifetime and runtime injection for an HTML custom sidebar.
@MainActor
final class CustomSidebarWebViewCoordinator: NSObject, WKNavigationDelegate {
    private static let actionMessageName = "cmuxSidebarAction"

    private var fileURL: URL
    private var dataContext: [String: SwiftValue]
    private var dispatch: SidebarActionDispatch
    private var contentInsets: CustomSidebarContentInsets
    private var colorScheme: ColorScheme
    private var lastRuntimeScript: String?
    private var actionHandler: CustomSidebarWebActionMessageHandler?

    init(
        fileURL: URL,
        dataContext: [String: SwiftValue],
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets,
        colorScheme: ColorScheme
    ) {
        self.fileURL = fileURL
        self.dataContext = dataContext
        self.dispatch = dispatch
        self.contentInsets = contentInsets
        self.colorScheme = colorScheme
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let handler = CustomSidebarWebActionMessageHandler(coordinator: self)
        actionHandler = handler
        configuration.userContentController.add(handler, name: Self.actionMessageName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: CustomSidebarWebBootstrapScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        load(fileURL, in: webView)
        pushRuntime(to: webView, force: true)
        return webView
    }

    func update(
        webView: WKWebView,
        fileURL: URL,
        dataContext: [String: SwiftValue],
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets,
        colorScheme: ColorScheme
    ) {
        let shouldLoad = self.fileURL != fileURL
        self.fileURL = fileURL
        self.dataContext = dataContext
        self.dispatch = dispatch
        self.contentInsets = contentInsets
        self.colorScheme = colorScheme

        if shouldLoad {
            lastRuntimeScript = nil
            load(fileURL, in: webView)
        }
        pushRuntime(to: webView, force: shouldLoad)
    }

    func dismantle(webView: WKWebView) {
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.actionMessageName)
        actionHandler = nil
    }

    func runAction(messageBody: Any) {
        guard let action = CustomSidebarWebActionParser().action(from: messageBody) else { return }
        dispatch.run(action)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushRuntime(to: webView, force: true)
    }

    private func load(_ fileURL: URL, in webView: WKWebView) {
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
    }

    private func pushRuntime(to webView: WKWebView, force: Bool) {
        guard let script = CustomSidebarWebRuntimePayload(
            fileURL: fileURL,
            dataContext: dataContext,
            contentInsets: contentInsets,
            colorScheme: colorScheme
        ).scriptSource else { return }
        guard force || script != lastRuntimeScript else { return }
        lastRuntimeScript = script
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}
