import AppKit
import WebKit

/// Routes links and file-open requests originating in a markdown preview panel
/// to the right cmux destination: local markdown files open as markdown
/// surfaces, `http(s)` links open in-app browser surfaces (or the system
/// browser when the in-app browser is disabled or the panel can't be located),
/// and other schemes (`mailto:`, `tel:`, `vscode://`, …) go to the system
/// handler. Owned by `MarkdownWebRenderer.Coordinator`, which keeps the
/// router's panel binding in sync via `bind(panelId:workspaceId:filePath:)`.
@MainActor
struct MarkdownLinkRouter {
    private let surfaceRouting: any MarkdownPanelSurfaceRouting
    private var panelId: UUID = UUID()
    private var workspaceId: UUID = UUID()
    private var filePath: String = ""

    init(surfaceRouting: any MarkdownPanelSurfaceRouting) {
        self.surfaceRouting = surfaceRouting
    }

    /// Re-bind the panel metadata the routing decisions depend on.
    mutating func bind(panelId: UUID, workspaceId: UUID, filePath: String) {
        self.panelId = panelId
        self.workspaceId = workspaceId
        self.filePath = filePath
    }

    /// Resolve a JS-bridge `resolveMarkdownFile` request and post the result
    /// back to the page via `window.__cmuxMarkdownFileResolved`.
    func resolveMarkdownFile(_ rawPath: String, requestId: String, on webView: WKWebView?) {
        guard let webView else { return }
        let resolved = resolvedMarkdownFilePath(rawPath)
#if DEBUG
        NSLog("MarkdownPanel.resolve raw=\(rawPath) resolved=\(resolved ?? "nil")")
#endif
        let payload: [String: Any] = [
            "requestId": requestId,
            "exists": resolved != nil,
            "path": resolved ?? ""
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__cmuxMarkdownFileResolved && window.__cmuxMarkdownFileResolved(\(json));", completionHandler: nil)
    }

    /// Resolve a raw link/path to an absolute markdown file path, or `nil` when
    /// it is empty or does not look like a markdown file.
    func resolvedMarkdownFilePath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard MarkdownPanelFileLinkResolver.isMarkdownPathLike(trimmed) else { return nil }
        return MarkdownPanelFileLinkResolver.resolve(rawPath: trimmed, relativeToMarkdownFile: filePath)
    }

    /// Open an already-resolved markdown file path as a markdown surface in this
    /// panel's pane. No-ops when the panel can't be located.
    func openMarkdownFile(_ path: String) {
#if DEBUG
        NSLog("MarkdownPanel.openMarkdownFile path=\(path)")
#endif
        _ = surfaceRouting.openMarkdownSurface(filePath: path, fromPanelId: panelId, preferredWorkspaceId: workspaceId)
    }

    /// Route a clicked link to a brand-new cmux browser tab in the same pane as
    /// this markdown panel — mirroring how Browser panels open child links via
    /// `openLinkInNewTab`. Falls back to the system browser only when the in-app
    /// browser is disabled or the panel can't be located in any workspace.
    func handleExternalLink(_ url: URL) {
#if DEBUG
        NSLog("MarkdownPanel.handleExternalLink url=\(url.absoluteString)")
#endif
        // First preference: links that resolve to local markdown files
        // open as markdown tabs in cmux, not in the browser.
        let fileCandidate = url.scheme == "file" ? url.path : url.absoluteString
        if let markdownPath = resolvedMarkdownFilePath(fileCandidate) {
            openMarkdownFile(markdownPath)
            return
        }

        // Schemes the in-app browser doesn't (and shouldn't) handle:
        // mailto:, tel:, slack://, vscode://, file:// non-markdown, etc.
        // Route those to the system handler so the user's default app picks them up.
        if let scheme = url.scheme?.lowercased(),
           scheme != "http", scheme != "https" {
            NSWorkspace.shared.open(url)
            return
        }

        guard BrowserAvailabilitySettings.isEnabled() else {
            NSWorkspace.shared.open(url)
            return
        }

        guard surfaceRouting.openBrowserSurface(url: url, fromPanelId: panelId, preferredWorkspaceId: workspaceId) else {
            // No workspace context — last-resort fallback.
            NSWorkspace.shared.open(url)
            return
        }
    }
}
