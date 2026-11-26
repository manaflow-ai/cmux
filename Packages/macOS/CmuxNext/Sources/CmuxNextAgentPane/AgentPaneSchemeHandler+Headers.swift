import Foundation

extension AgentPaneSchemeHandler {
    /// The policy every file but the page document is served with. A worker (the pane's code
    /// highlighter, `highlight-worker.js`) takes its policy from its own response, not from the
    /// page's meta tag, so this keeps it from opening any connection or loading anything. Other
    /// scripts and resources ignore a response policy. The page document has its meta tag
    /// (scripts/cmux-next/build-agent-pane-web.sh); a second header policy would intersect with it.
    nonisolated static let resourcePolicy = "default-src 'none'"

    /// The response headers for `file`, `length` bytes long.
    nonisolated static func headers(for file: URL, length: Int) -> [String: String] {
        let ext = file.pathExtension.lowercased()
        var headers = [
            "Content-Type": ext == "js" || ext == "mjs" ? "text/javascript" : ext == "html" ? "text/html" : mimeType(forExtension: ext),
            "Content-Length": String(length),
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        ]
        if ext != "html" { headers["Content-Security-Policy"] = resourcePolicy }
        return headers
    }
}
