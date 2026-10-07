import Foundation

/// The frame a render card shows an agent's HTML in (`conversation/RenderCard.tsx`):
/// `cmux-agent://render/frame`, an origin of its own beside the pane's `cmux-agent://pane`. The
/// card frames it sandboxed without same-origin, so the HTML runs with an opaque origin and
/// cannot reach the pane, its bridge or acpmux.
///
/// The document (renderFrame.html) waits for its parent's `cmux-render` message, writes the HTML
/// into itself and reports its height back as `cmux-render-size`. The policy allows inline
/// and evaluated script and the script CDNs a mock or chart loads its library from, and no
/// connection, frame, form or remote image.
nonisolated enum AgentPaneRenderFrame {
    static let host = "render"
    static let path = "/frame"

    /// True for the frame document's URL, and nothing else on the render host.
    static func isFrame(_ url: URL) -> Bool {
        url.scheme?.lowercased() == AgentPaneSource.bundledScheme && url.host?.lowercased() == host
            && url.path == path && url.port == nil && url.user == nil
    }

    static let policy = [
        "default-src 'none'",
        "script-src 'unsafe-inline' 'unsafe-eval' \(cdns)",
        "style-src 'unsafe-inline' https://fonts.googleapis.com \(cdns)",
        "font-src data: https://fonts.gstatic.com \(cdns)",
        "img-src data: blob:",
        "media-src data: blob:",
        "connect-src 'none'",
        "frame-src 'none'",
        "form-action 'none'",
        "base-uri 'none'",
    ].joined(separator: "; ")

    private static let cdns = "https://cdn.jsdelivr.net https://unpkg.com https://cdnjs.cloudflare.com"

        /// The document (webviews/src/agent-session/acpmux/renderFrame.html, copied beside the pane by
    /// scripts/cmux-next/build-agent-pane-web.sh). It carries `policy` as a meta tag too, for the
    /// gallery's host, which serves the same file.
    static let fileName = "render-frame.html"
    static let document: Data = Bundle.module.url(forResource: "render-frame", withExtension: "html", subdirectory: "agent-pane")
        .flatMap { try? Data(contentsOf: $0) } ?? Data()

    static func headers(length: Int) -> [String: String] {
        [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": String(length),
            "Content-Security-Policy": policy,
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
        ]
    }
}
