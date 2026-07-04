import AppKit
import SwiftUI
import WebKit

struct IssueInboxPanelWebView: NSViewRepresentable {
    let panel: IssueInboxPanel
    let workspaceId: UUID
    let isFocused: Bool
    let backgroundColor: NSColor
    let theme: AgentSessionWebTheme
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> IssueInboxBridge {
        IssueInboxBridge()
    }

    func makeNSView(context: Context) -> NSView {
        let host = AgentSessionWebHostView()
        host.wantsLayer = true
        applyBackground(to: host)
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? AgentSessionWebHostView else { return }
        context.coordinator.bind(
            panelId: panel.id,
            workspaceId: workspaceId,
            theme: theme,
            isFocused: isFocused
        )
        let webView = context.coordinator.ensureWebView(onPointerDown: onRequestPanelFocus)
        webView.onPointerDown = onRequestPanelFocus
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        applyBackground(to: host)
        applyBackground(to: webView)
        applyAppearance(to: webView)
        host.attachWebView(webView)
        host.onDidMoveToWindow = { [weak coordinator = context.coordinator] in
            coordinator?.loadShellIfNeeded()
            coordinator?.flushVisiblePaintIfReady()
        }
        host.onGeometryChanged = { [weak coordinator = context.coordinator] in
            coordinator?.flushVisiblePaintIfReady()
        }
        context.coordinator.loadShellIfNeeded()
        context.coordinator.flushVisiblePaintIfReady()
        if isFocused {
            context.coordinator.focus()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: IssueInboxBridge) {
        if let host = nsView as? AgentSessionWebHostView {
            host.detachHostedWebViewIfOwned(coordinator.webView)
            host.onDidMoveToWindow = nil
            host.onGeometryChanged = nil
        }
        coordinator.close()
    }

    private func applyBackground(to host: NSView) {
        host.wantsLayer = true
        host.layer?.backgroundColor = backgroundColor.cgColor
        host.layer?.isOpaque = backgroundColor.alphaComponent >= 0.999
    }

    private func applyBackground(to webView: WKWebView) {
        webView.underPageBackgroundColor = backgroundColor
        webView.wantsLayer = true
        webView.layer?.backgroundColor = backgroundColor.cgColor
        webView.layer?.isOpaque = backgroundColor.alphaComponent >= 0.999
    }

    private func applyAppearance(to webView: WKWebView) {
        let appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        if webView.appearance !== appearance {
            webView.appearance = appearance
        }
    }
}

struct IssueInboxPanelView: View {
    let panel: IssueInboxPanel
    let workspaceId: UUID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        Group {
            if isVisibleInUI {
                IssueInboxPanelWebView(
                    panel: panel,
                    workspaceId: workspaceId,
                    isFocused: isFocused,
                    backgroundColor: appearance.contentBackgroundColor,
                    theme: AgentSessionWebTheme.resolve(appearance: appearance),
                    onRequestPanelFocus: onRequestPanelFocus
                )
                .id(panel.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(Double(portalPriority))
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
}
