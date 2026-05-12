import AppKit
import Bonsplit
import SwiftUI

struct ExtensionPanelView: View {
    @ObservedObject var panel: ExtensionPanel
    let paneId: PaneID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let onRequestPanelFocus: () -> Void

    var body: some View {
        ExtensionWebViewRepresentable(
            panel: panel,
            paneId: paneId,
            isFocused: isFocused,
            isVisibleInUI: isVisibleInUI,
            onRequestPanelFocus: onRequestPanelFocus
        )
    }
}

private struct ExtensionWebViewRepresentable: NSViewRepresentable {
    @ObservedObject var panel: ExtensionPanel
    let paneId: PaneID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let onRequestPanelFocus: () -> Void

    func makeNSView(context: Context) -> ExtensionWebViewHost {
        let host = ExtensionWebViewHost()
        host.postsFrameChangedNotifications = true
        return host
    }

    func updateNSView(_ nsView: ExtensionWebViewHost, context: Context) {
        panel.onRequestPanelFocus = onRequestPanelFocus
        panel.updatePaneId(paneId.id)
        nsView.install(webView: panel.webView)
        nsView.isHidden = !isVisibleInUI

        if isFocused && isVisibleInUI {
            panel.focus()
        }
    }

    static func dismantleNSView(_ nsView: ExtensionWebViewHost, coordinator: ()) {
        nsView.uninstallWebView()
    }
}

private final class ExtensionWebViewHost: NSView {
    private weak var hostedWebView: NSView?

    override var isFlipped: Bool { true }

    func install(webView: NSView) {
        if hostedWebView !== webView {
            hostedWebView?.removeFromSuperview()
            hostedWebView = webView
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
        }
        webView.frame = bounds
        webView.isHidden = false
    }

    func uninstallWebView() {
        hostedWebView?.removeFromSuperview()
        hostedWebView = nil
    }

    override func layout() {
        super.layout()
        hostedWebView?.frame = bounds
    }
}
