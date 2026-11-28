import Foundation

/// The frame a render card shows an agent's HTML in (`conversation/RenderCard.tsx`):
/// `cmux-agent://render/frame`, an origin of its own beside the pane's `cmux-agent://pane`. The
/// card frames it sandboxed without same-origin, so the HTML runs with an opaque origin and
/// cannot reach the pane, its bridge or acpmux.
///
/// The document waits for its parent's `cmux-render` message, writes the HTML into itself
/// (`document.open` keeps the document, so this policy still applies), puts the pane's theme
/// first in its head and reports its height back as `cmux-render-size`. The policy allows inline
/// and evaluated script and the script CDNs a mock or chart loads its library from, and no
/// connection, frame, form or remote image.
nonisolated enum AgentPaneRenderFrame {
    static let host = "render"
    static let path = "/frame"
    /// The frame's origin, for the pane's CSP `frame-src` (PageDescriptor.agent).
    static let source = "cmux-agent://\(host)"

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

    static let document = Data(#"""
    <!doctype html>
    <html><head><meta charset="utf-8"><script>
    "use strict";
    (function () {
      var host = parent;
      function size() {
        var body = document.body;
        var height = Math.max(document.documentElement.scrollHeight, body ? body.scrollHeight : 0);
        host.postMessage({ type: "cmux-render-size", height: Math.ceil(height) }, "*");
      }
      function show(event) {
        var data = event.data;
        if (event.source !== host || !data || data.type !== "cmux-render" || typeof data.html !== "string") return;
        removeEventListener("message", show);
        document.open();
        document.write(data.html);
        document.close();
        var theme = document.createElement("style");
        theme.textContent = typeof data.css === "string" ? data.css : "";
        var head = document.head || document.documentElement;
        head.insertBefore(theme, head.firstChild);
        new ResizeObserver(size).observe(document.documentElement);
        addEventListener("load", size);
        size();
      }
      addEventListener("message", show);
      host.postMessage({ type: "cmux-render-ready" }, "*");
    })();
    </script></head></html>
    """#.utf8)

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
