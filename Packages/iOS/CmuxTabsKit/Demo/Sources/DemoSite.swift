import UIKit
import WebKit

/// The demo's local "web": `tabskit://pages/<name>` and
/// `tabskit://search?q=...`, served from memory so the demo needs no network.
struct DemoSite {
    static let scheme = "tabskit"
    static let start = URL(string: "tabskit://pages/start")!

    struct Page {
        var name: String
        var title: String
        var color: UInt32
        var text: String
    }

    static let pages: [Page] = [
        Page(name: "start", title: "Start Page", color: 0xF2F2F7, text: ""),
        Page(name: "springs", title: "Springs", color: 0xFF9F0A,
             text: "Every transition in the kit is a damped spring fitted to Mobile Safari recordings: the tab zoom, the toolbar collapse, the card reflow."),
        Page(name: "glass", title: "Liquid Glass", color: 0x0A84FF,
             text: "The toolbar is three separate glass shapes: the back capsule, the address capsule and the tabs circle. Scroll this page to collapse them into the pill."),
        Page(name: "pinch", title: "Pinch", color: 0x30D158,
             text: "Pinch in on a page to shrink it into its card in the grid; pinch out on a card to open it. A pinch can grab a zoom that is still running."),
        Page(name: "night", title: "Night Mode", color: 0x1C1C1E,
             text: "A dark page header asks for light status bar content through the tab's statusBarStyle."),
    ]

    static func page(for url: URL) -> Page? {
        guard url.scheme == scheme, url.host() == "pages" else { return nil }
        return pages.first { $0.name == url.lastPathComponent }
    }

    static func searchQuery(_ url: URL) -> String? {
        guard url.scheme == scheme, url.host() == "search" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
    }

    /// A URL for what was typed in the address field.
    static func url(for text: String) -> URL? {
        if text.contains("://") { return URL(string: text) }
        if let page = pages.first(where: { $0.name == text.lowercased() }) { return URL(string: "tabskit://pages/\(page.name)") }
        if text.contains("."), !text.contains(" ") { return URL(string: "https://\(text)") }
        var c = URLComponents(string: "tabskit://search")!
        c.queryItems = [URLQueryItem(name: "q", value: text)]
        return c.url
    }

    static func hex(_ v: UInt32) -> String { String(format: "#%06X", v) }

    static func html(for url: URL) -> String {
        let links = pages.filter { $0.name != "start" }
            .map { "<a class=\"tile\" style=\"background:\(hex($0.color))\" href=\"tabskit://pages/\($0.name)\">\($0.title)</a>" }
            .joined()
        let body: String
        let color: UInt32
        if let q = searchQuery(url) {
            color = 0xF2F2F7
            let hits = pages.filter { $0.name != "start" && ($0.title.localizedCaseInsensitiveContains(q) || $0.text.localizedCaseInsensitiveContains(q)) }
            let list = hits.isEmpty ? "<p>No results.</p>" : hits.map { "<p><a href=\"tabskit://pages/\($0.name)\">\($0.title)</a></p>" }.joined()
            body = "<header style=\"background:\(hex(color));color:#000\"><h1>“\(escape(q))”</h1></header><main>\(list)</main>"
        } else if let page = page(for: url), page.name != "start" {
            color = page.color
            let fg = TabsKitStatusBarStyleProbe.isDark(page.color) ? "#fff" : "#000"
            let filler = (1...12).map { "<p>\(page.text) Paragraph \($0).</p>" }.joined()
            body = "<header style=\"background:\(hex(color));color:\(fg)\"><h1>\(page.title)</h1></header><main><nav>\(links)</nav>\(filler)</main>"
        } else {
            color = 0xF2F2F7
            body = "<main class=\"start\"><h2>Favorites</h2><nav>\(links)</nav></main>"
        }
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(searchQuery(url).map { "Search: \(escape($0))" } ?? page(for: url)?.title ?? "Start Page")</title>
        <style>
        body{margin:0;font:17px -apple-system;background:\(hex(color == 0x1C1C1E ? 0x000000 : 0xFFFFFF));color:\(color == 0x1C1C1E ? "#eee" : "#111")}
        header{padding:24px 20px 28px} h1{margin:0;font-size:34px}
        main{padding:8px 20px 40px} .start{background:#F2F2F7;min-height:100vh}
        nav{display:flex;flex-wrap:wrap;gap:12px;margin:12px 0 20px}
        .tile{display:block;width:72px;height:72px;border-radius:16px;color:#fff;font-size:12px;text-decoration:none;
              display:flex;align-items:flex-end;justify-content:center;padding-bottom:6px;box-sizing:border-box}
        p{line-height:1.45}
        </style></head><body>\(body)</body></html>
        """
    }

    static func headerColor(for url: URL?) -> UIColor {
        let hex = url.flatMap(page(for:))?.color ?? 0xF2F2F7
        return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }
}

/// Luminance check for the page headers.
struct TabsKitStatusBarStyleProbe {
    static func isDark(_ hex: UInt32) -> Bool {
        let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        return 0.299 * r + 0.587 * g + 0.114 * b < 128
    }
}

/// Serves `DemoSite` pages to the web views.
final class DemoSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let data = Data(DemoSite.html(for: url).utf8)
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
