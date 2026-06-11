import AppKit
import SwiftUI
import WebKit

/// SwiftUI host for the markdown panel's edit mode: the same Monaco `editor`
/// webviews surface `cmux edit` opens in a browser split, mounted inside the
/// panel's edit region and wired to the panel's own content + save model
/// (see ``MarkdownEditorRendererCoordinator``).
struct MarkdownEditorRenderer: NSViewRepresentable {
    let panel: MarkdownPanel
    let isFocused: Bool
    let appearance: PanelAppearance
    /// Soft line wrapping, sourced from the persisted `fileEditor.wordWrap`
    /// setting; updates apply live.
    let wordWrap: Bool
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> MarkdownEditorRendererCoordinator {
        panel.editorSession.coordinator(panel: panel)
    }

    func makeNSView(context: Context) -> MarkdownEditorWebView {
        let webView = context.coordinator.ensureWebView(onPointerDown: onRequestPanelFocus)
        if webView.superview != nil {
            webView.removeFromSuperview()
        }
        configure(webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ nsView: MarkdownEditorWebView, context: Context) {
        configure(nsView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: MarkdownEditorWebView, coordinator: MarkdownEditorRendererCoordinator) {
        // The session-owned coordinator retains the webview across unmounts
        // (preview toggles, layout churn) so the buffer and undo stack
        // survive; only a closed panel tears it down.
        if let retainedWebView = coordinator.webView, retainedWebView === nsView {
            return
        }
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        nsView.onPointerDown = nil
        nsView.onEditorKeyEquivalent = nil
    }

    private func configure(_ webView: MarkdownEditorWebView, coordinator: MarkdownEditorRendererCoordinator) {
        coordinator.bind(panel: panel)
        webView.onPointerDown = onRequestPanelFocus
        applyBackground(to: webView)
        coordinator.presentEditor(appearance: appearance, wordWrap: wordWrap)
        if isFocused {
            coordinator.focus()
        }
    }

    private func applyBackground(to webView: WKWebView) {
        let backgroundColor = appearance.backgroundColor.markdownOpaqueSRGB
        webView.underPageBackgroundColor = backgroundColor
        webView.wantsLayer = true
        webView.layer?.backgroundColor = backgroundColor.cgColor
        webView.layer?.isOpaque = true
    }
}
