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
        let preparation = AgentPaneRenderPreviewPreparation { [webView] completion in
            webView.callAsyncJavaScript(
                "if (typeof window.cmuxPrepareRenderPreview !== 'function') return {error: 'not_laid_out'}; try { return window.cmuxPrepareRenderPreview(html, width === null ? undefined : width); } catch (error) { return {error: error.code || 'render_failed'}; }",
                arguments: ["html": html, "width": width.map { $0 as Any } ?? NSNull()], in: nil, in: .page,
                completionHandler: completion)
        }
        return try await renderPreview(html: html, width: width, dataStore: dataStore, park: park, preparation: preparation)
    }

    func renderPreview(html: String, width: Int? = nil, dataStore: WKWebsiteDataStore,
                       park: @MainActor (WKWebView) -> (@MainActor () -> Void),
                       preparation: AgentPaneRenderPreviewPreparation) async throws -> String {
        try Task.checkCancellation()
        _ = try AgentPaneRenderPreviewInput(html: html, width: width)
        guard !renderPreviewInFlight else { throw AgentPaneRenderPreviewError.busy }
        renderPreviewInFlight = true
        defer { renderPreviewInFlight = false }
        let prepared = try await preparation.run()
        try Task.checkCancellation()
        let preview = AgentPaneRenderPreview()
        return try await preview.capture(document: prepared.html, width: prepared.width,
                                         dark: prepared.dark, dataStore: dataStore, park: park)
    }
}
