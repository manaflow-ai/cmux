import Foundation

/// cmux: what Home links in an agent's text when the agent wrote no link (Lawrence 2026-10-19,
/// "links for everything possible, including paths"): an absolute path (`/Users/…`, `~/…`, under
/// a local root) as a path link (`URL.isHomePathLink`), a cmux id (`ws_…`, `pane_…`, `tab_…`,
/// 32 hex digits) and a `cmux://` link as its app link (`URL.isCmuxAppLink`). Everything still
/// goes through `MarkdownLinkPolicy`, so `javascript:`, `data:` and the like never link. Bare
/// GitHub numbers are not linked: the text names no repository (the Chief's prompt links them).
extension HomeMarkdown {
    /// One bare link found in plain text: its UTF-16 range and the link it opens.
    struct AutoLink: Equatable {
        var range: NSRange
        var link: String
    }

    /// The bare links in `text`, left to right, each one accepted by the link policy.
    static func autoLinks(in text: String) -> [AutoLink] {
        let ns = text as NSString
        guard ns.length > 2, text.contains(where: { $0 == "/" || $0 == "_" }) else { return [] }
        var found: [AutoLink] = []
        for match in autoLinkPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var range = match.range
            // A sentence's punctuation after a path is not part of it.
            while range.length > 1, let last = ns.substring(with: NSRange(location: range.location + range.length - 1, length: 1)).unicodeScalars.first,
                  ".,:;!?".unicodeScalars.contains(last) {
                range.length -= 1
            }
            guard let link = destination(ns.substring(with: range)) else { continue }
            found.append(AutoLink(range: range, link: link))
        }
        return found
    }

    /// `raw` as the link Home opens: a path as a path link, a bare cmux id as its app link,
    /// anything else as written; then the one link rule (`MarkdownLinkPolicy`). Nil: no link.
    static func destination(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("/") || s.hasPrefix("~/") {
            let path = s.hasPrefix("~/") ? NSHomeDirectory() + String(s.dropFirst()) : s
            return MarkdownLinkPolicy.sanitize(URL(fileURLWithPath: path).absoluteString)
        }
        for (prefix, host) in [("ws_", "workspace"), ("pane_", "pane"), ("tab_", "tab")] where s.hasPrefix(prefix) {
            return MarkdownLinkPolicy.sanitize("cmux://\(host)/\(s)")
        }
        return MarkdownLinkPolicy.sanitize(s)
    }

    /// A path under a local root, a cmux id, or a `cmux://` link, standing alone (not inside a
    /// longer word, URL or path).
    private static let autoLinkPattern: NSRegularExpression = {
        let part = #"[^\s/<>()\[\]"'`*|]"#
        let roots = "Users|tmp|private|Applications|Library|System|Volumes|opt|usr|var|etc"
        let path = #"(?:~/\#(part)+(?:/\#(part)*)*|/(?:\#(roots))/\#(part)+(?:/\#(part)*)*|/(?:\#(roots))/?(?=[\s.,:;!?)]|$))"#
        let id = #"(?:ws|pane|tab)_[0-9a-f]{32}(?![0-9A-Za-z_])"#
        let cmux = #"cmux(?:-[a-z0-9-]+)?://[^\s<>()\[\]"'`*|]+"#
        // Crash program: a constant pattern, checked by the tests.
        return try! NSRegularExpression(pattern: #"(?<![\w/:.~\-])(?:\#(path)|\#(id)|\#(cmux))"#)
    }()
}

extension HomeMarkdown.Output {
    /// Appends plain text, linking each bare path, cmux id and cmux link in it
    /// (``HomeMarkdown/autoLinks(in:)``).
    mutating func appendLinkingBare(_ s: String, _ styles: [String]) {
        let links = HomeMarkdown.autoLinks(in: s)
        guard !links.isEmpty else { return append(s, styles) }
        let ns = s as NSString
        var at = 0
        for found in links {
            append(ns.substring(with: NSRange(location: at, length: found.range.location - at)), styles)
            append(ns.substring(with: found.range), styles, link: found.link)
            at = found.range.location + found.range.length
        }
        append(ns.substring(from: at), styles)
    }
}
