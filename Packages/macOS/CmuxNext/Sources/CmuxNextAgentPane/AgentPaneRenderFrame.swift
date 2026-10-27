import CmuxNextPages
import Foundation

/// The frame a render card shows an agent's HTML in (`conversation/RenderCard.tsx`):
/// `cmux-page://cmux.agent/__render/frame` on the page host (``AgentPageResources``). The page host
/// serves it with its own policy behind `sandbox allow-scripts` (``PageResource/sandboxedPolicy``),
/// and the card frames it sandboxed without same-origin too, so the HTML always runs with an
/// opaque origin and cannot reach the pane, its bridge or acpmux. Only the WebKit page host serves
/// a document its own policy, so the page frames renders only there (`data-engine="webkit"`).
///
/// The document waits for its parent's `cmux-render` message, writes the HTML into itself
/// (`document.open` keeps the document, so this policy still applies), puts the pane's theme
/// first in its head and reports its height back as `cmux-render-size`. The policy allows inline
/// and evaluated script and the script CDNs a mock or chart loads its library from, and no
/// connection, frame, form or remote image.
nonisolated enum AgentPaneRenderFrame {
    /// The agent page's dynamic prefix the frame is served under (``PageDescriptor/agent``).
    static let prefix = "__render"
    /// The frame document's one name under ``prefix``.
    static let name = "frame"
    /// The frame's URL, for the pane's CSP `frame-src` (PageDescriptor.agent): this document only.
    static let source = "\(PageDescriptor.scheme)://cmux.agent/\(prefix)/\(name)"

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

    /// The frame document as the page host serves it.
    static var resource: PageResource {
        PageResource(data: document, mimeType: "text/html; charset=utf-8", sandboxedPolicy: policy)
    }
}
