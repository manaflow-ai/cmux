import Foundation
public import WebKit

extension AgentPaneView {
    /// Captures agent HTML using this pane's resolved frame styles, labs and reply width.
    ///
    /// - Parameters:
    ///   - html: A nonempty page, at most 1 MiB of UTF-8.
    ///   - width: An optional alternate viewport, from 320 to 1440 CSS pixels.
    ///   - dataStore: The preview service's ephemeral store, shared to cache CDN scripts.
    ///   - park: Installs the view off-screen and returns its idempotent cleanup.
    /// - Returns: JSON containing the PNG and bounded diagnostics, with no native bridge in the preview.
    /// - Throws: If disabled, busy, oversized, timed out, or WebKit fails.
    public func renderPreview(html: String, width: Int? = nil, dataStore: WKWebsiteDataStore,
                              park: @MainActor (WKWebView) -> (@MainActor () -> Void)) async throws -> String {
        _ = try AgentPaneRenderPreviewInput(html: html, width: width)
        guard !renderPreviewInFlight else { throw AgentPaneRenderPreviewError.busy }
        renderPreviewInFlight = true
        defer { renderPreviewInFlight = false }
        let raw = try await webView.callAsyncJavaScript(
            "if (typeof window.cmuxPrepareRenderPreview !== 'function') return {error: 'not_laid_out'}; try { return window.cmuxPrepareRenderPreview(html, width === null ? undefined : width); } catch (error) { return {error: error.code || 'render_failed'}; }",
            arguments: ["html": html, "width": width.map { $0 as Any } ?? NSNull()], in: nil, contentWorld: .page)
        if let prepared = raw as? [String: Any], let code = prepared["error"] as? String {
            throw AgentPaneRenderPreviewError(rawValue: code) ?? .failed
        }
        guard let prepared = raw as? [String: Any], let document = prepared["document"] as? String,
              let width = prepared["width"] as? Int, (1...1440).contains(width) else {
            throw AgentPaneRenderPreviewError.notLaidOut
        }
        let preview = AgentPaneRenderPreview()
        return try await preview.capture(document: document, width: width,
                                         dark: prepared["theme"] as? String == "dark", dataStore: dataStore, park: park)
    }
}
