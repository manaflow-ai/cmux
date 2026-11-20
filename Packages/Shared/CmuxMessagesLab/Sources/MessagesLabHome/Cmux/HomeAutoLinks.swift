import Foundation

/// cmux: what Home links in an agent's text when the agent wrote no link (Lawrence 2026-10-19,
/// "links for everything possible, including paths"): an absolute path (`/Users/…`, `~/…`, under
/// a local root) as a path link (`URL.isHomePathLink`), a cmux id (`ws_…`, `pane_…`, `tab_…`,
/// 32 hex digits) and a `cmux://` link as its app link (`URL.isCmuxAppLink`), and a bare
/// `http(s)://` URL as itself (Lawrence 2026-10-23: a Chief's `**https://github.com/login/device**`
/// was bold text no click opened; only a URL alone on its line became a card), a GitHub pull
/// request, issue, commit or run URL shown by its short name. Everything still
/// goes through `MarkdownLinkPolicy`, so `javascript:`, `data:` and the like never link. Bare
/// GitHub numbers are not linked: the text names no repository (the Chief's prompt links them).
extension HomeMarkdown {
    /// One bare link found in plain text: its UTF-16 range, the link it opens and the short
    /// label Home shows in its place (``shortLabel(_:)``).
    struct AutoLink: Equatable {
        var range: NSRange
        var link: String
        var label: String
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
            let raw = ns.substring(with: range)
            guard let link = destination(raw) else { continue }
            found.append(AutoLink(range: range, link: link, label: shortLabel(raw)))
        }
        return found
    }

    /// The label a bare link shows (Lawrence 2026-10-19: a raw `cmux://workspace/ws_…` broke
    /// across two lines): a short path as written (the home folder as `~`), a long one as its
    /// file name; a cmux link or id as its id, cut after 8 characters (`ws_9166682e…`). Short
    /// and without spaces, so the link wraps as one unit.
    static func shortLabel(_ raw: String) -> String {
        // A GitHub pull request, issue, commit or run shows by its short name (cmux#25572: a reply
        // never shows a raw URL); any other web URL as written: the person may need to read or
        // type it (a sign-in page).
        if raw.hasPrefix("https://") || raw.hasPrefix("http://") { return githubLabel(raw) ?? raw }
        if raw.hasPrefix("/") || raw.hasPrefix("~/") {
            let home = NSHomeDirectory()
            let path = raw.hasPrefix(home + "/") ? "~" + raw.dropFirst(home.count) : raw
            return path.utf16.count <= 40 ? path : (path as NSString).lastPathComponent
        }
        let id = raw.split(separator: "/").last.map(String.init) ?? raw
        if let underscore = id.firstIndex(of: "_"), id.distance(from: underscore, to: id.endIndex) > 9 {
            return String(id.prefix(id.distance(from: id.startIndex, to: underscore) + 9)) + "…"
        }
        return id.count > 16 ? String(id.prefix(12)) + "…" : id
    }

    /// The short name of a GitHub pull request or issue (`#123`), commit (`abc1234`) or Actions
    /// run (`run 39221907733`) URL, the names a Chief writes them with; nil for any other URL.
    static func githubLabel(_ raw: String) -> String? {
        guard let url = URL(string: raw), let kind = HomeLinkChip.kind(for: raw) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        switch kind {
        case .pullRequest, .issue: return "#" + parts[3]
        case .commit: return String(parts[3].prefix(7))
        case .run: return "run " + parts[4]
        default: return nil
        }
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

    /// A path under a local root, a cmux id, a `cmux://` link or a web URL, standing alone (not
    /// inside a longer word, URL or path).
    private static let autoLinkPattern: NSRegularExpression = {
        let part = #"[^\s/<>()\[\]"'`*|]"#
        let roots = "Users|tmp|private|Applications|Library|System|Volumes|opt|usr|var|etc"
        let path = #"(?:~/\#(part)+(?:/\#(part)*)*|/(?:\#(roots))/\#(part)+(?:/\#(part)*)*|/(?:\#(roots))/?(?=[\s.,:;!?)]|$))"#
        let id = #"(?:ws|pane|tab)_[0-9a-f]{32}(?![0-9A-Za-z_])"#
        let cmux = #"cmux(?:-[a-z0-9-]+)?://[^\s<>()\[\]"'`*|]+"#
        let web = #"https?://[^\s<>()\[\]"'`*|]+"#
        // Crash program: a constant pattern, checked by the tests.
        return try! NSRegularExpression(pattern: #"(?<![\w/:.~\-])(?:\#(web)|\#(path)|\#(id)|\#(cmux))"#)
    }()
}

extension HomeMarkdown.Output {
    /// Appends plain text, each bare path, cmux id, cmux link and web URL in it shown as its short
    /// label and linked (``HomeMarkdown/autoLinks(in:)``).
    mutating func appendLinkingBare(_ s: String, _ styles: [String]) {
        let links = HomeMarkdown.autoLinks(in: s)
        guard !links.isEmpty else { return append(s, styles) }
        let ns = s as NSString
        var at = 0
        for found in links {
            append(ns.substring(with: NSRange(location: at, length: found.range.location - at)), styles)
            append(found.label, styles, link: found.link)
            at = found.range.location + found.range.length
        }
        append(ns.substring(from: at), styles)
    }
}
