import Foundation

/// The text of a link Chromium's context menu names by address only.
enum CEFLinkText {
    /// The visible text of the main frame's first link to `url` in `tab`;
    /// empty when no link in the main frame matches or the page does not
    /// answer. One DevTools round trip in the page world: a page can only
    /// misreport its own text.
    static func text(for url: URL, in tab: CEFTab) async -> String {
        guard let quoted = (try? JSONEncoder().encode(url.absoluteString)).flatMap({ String(data: $0, encoding: .utf8) }) else { return "" }
        let script = """
        (() => { const u = \(quoted); for (const a of document.links) { if (a.href === u) \
        return (a.innerText || a.textContent || '').trim().slice(0, 4096); } return ''; })()
        """
        guard case .string(let text)? = try? await tab.evaluate(script, world: .page) else { return "" }
        return text
    }
}
