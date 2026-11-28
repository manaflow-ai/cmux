#if os(iOS) && canImport(WebKit)
import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The Mac's React agent pane on the phone: the bundled `agent-pane/` (built by
/// `scripts/cmux-next/build-agent-pane-web.sh`) loaded from `cmux-agent://pane/index.html`, the Mac's
/// origin, with ``AgentPaneWebBridge`` answering its `agentSession` bridge over the Mac link.
public struct AgentPaneWebView: UIViewRepresentable {
    public let sessionID: String?
    public let machineName: String?
    public let openChannel: AgentPaneWebBridge.OpenChannel
    /// The bundled pane (the app's `agent-pane` resource folder), or nil when this build has none.
    public let root: URL?

    public init(sessionID: String?, machineName: String?, root: URL? = AgentPaneWebView.bundledRoot,
                openChannel: @escaping AgentPaneWebBridge.OpenChannel) {
        self.sessionID = sessionID
        self.machineName = machineName
        self.root = root
        self.openChannel = openChannel
    }

    /// The app's bundled pane, when its `index.html` is there.
    public static var bundledRoot: URL? {
        guard let url = Bundle.main.url(forResource: "agent-pane", withExtension: nil),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("index.html").path) else { return nil }
        return url
    }

    public static let scheme = "cmux-agent"
    public static let host = "pane"
    public static let page = URL(string: "cmux-agent://pane/index.html")!

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let coordinator = context.coordinator
        if let root { configuration.setURLSchemeHandler(AgentPaneWebSchemeHandler(root: root), forURLScheme: Self.scheme) }
        configuration.userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: "agentSession")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        webView.isInspectable = true
        #endif
        coordinator.bridge = AgentPaneWebBridge(sessionID: sessionID, machineName: machineName, openChannel: openChannel) { [weak webView] script in
            webView?.evaluateJavaScript(script, completionHandler: nil)
        }
        if root != nil {
            webView.load(URLRequest(url: Self.page))
        } else {
            webView.loadHTMLString(Self.missingPage, baseURL: nil)
        }
        return webView
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {}

    public static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.bridge?.closeAll()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "agentSession", contentWorld: .page)
    }

    static let missingPage = """
    <html><body style="font: -apple-system-body; color: gray; text-align: center; padding-top: 40vh">
    This build has no web agent pane. Build it with scripts/cmux-next/build-agent-pane-web.sh.
    </body></html>
    """

    /// Answers the page's `agentSession` messages; only the bundled page's main frame is heard.
    @MainActor public final class Coordinator: NSObject, WKScriptMessageHandlerWithReply {
        var bridge: AgentPaneWebBridge?

        public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                          replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard message.frameInfo.isMainFrame, AgentPaneWebView.isTrusted(message.frameInfo.request.url), let bridge else {
                replyHandler(AgentPaneWebBridge.failure("native.untrusted", "Only the agent pane may call the host."), nil)
                return
            }
            let body = message.body
            Task { @MainActor in replyHandler(await bridge.handle(body), nil) }
        }
    }

    /// The bundled page itself: `cmux-agent://pane/index.html`, no port.
    nonisolated static func isTrusted(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == scheme && url.host?.lowercased() == host && url.port == nil
            && url.path == "/index.html"
    }
}

/// Serves `agent-pane/` under `cmux-agent://pane/`; the drawn-copy script is an empty stub, as on a
/// Mac host that keeps no snapshots.
final class AgentPaneWebSchemeHandler: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard task.request.httpMethod.map({ $0 == "GET" }) ?? true, let url = task.request.url else {
            return task.didFailWithError(URLError(.unsupportedURL))
        }
        let data: Data
        let file: URL
        if url.path == "/__snapshot/chat.js" {
            data = Data("self.__cmuxChatSnapshot=null;".utf8)
            file = URL(fileURLWithPath: "chat.js")
        } else if let found = Self.fileURL(for: url, root: root), let read = try? Data(contentsOf: found, options: .mappedIfSafe) {
            data = read
            file = found
        } else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let headers = ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-cache"]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// The file `url` names inside `root`, or nil for another scheme or host, or a path leaving it.
    static func fileURL(for url: URL, root: URL) -> URL? {
        guard url.scheme?.lowercased() == AgentPaneWebView.scheme, url.host?.lowercased() == AgentPaneWebView.host else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        let file = parts.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL.resolvingSymlinksInPath()
        return file.path.hasPrefix(root.path + "/") ? file : nil
    }
}

extension AcpmuxSessionSource: AgentPaneWebHosting {
    /// This chat in the web pane: each page connection is a fresh `acpmux` channel on the hub's link.
    public func agentPaneWebView() -> AnyView {
        let hub = hub
        return AnyView(AgentPaneWebView(sessionID: sessionID, machineName: summary.macName) {
            guard let link = hub?.macLink else { throw LinkError(code: "offline", message: "Not connected to the Mac.") }
            return try await link.openChannel(service: "acpmux", args: AcpmuxConnection.channelArgs)
        }
        .ignoresSafeArea(edges: .bottom))
    }
}
#endif
