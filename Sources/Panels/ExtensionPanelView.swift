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

struct BlockedExtensionPanelView: View {
    @ObservedObject var panel: BlockedExtensionPanel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: panel.isLoading ? "puzzlepiece.extension" : "exclamationmark.triangle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(panel.isLoading ? .secondary : .orange)
            Text(panel.statusTitle)
                .font(.headline)
            Text(panel.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 520)
            Text(panel.bundlePath)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: 520)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
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
