import Foundation

/// Renders Markdown to HTML for the local live link (plans/cmux-next/markdown-omnibar-DESIGN.md
/// section 4.1) with Foundation's full Markdown parser. Every text run is escaped and raw HTML in
/// the Markdown is never passed through, so a shared file cannot put markup or script on the page;
/// links keep only `http`, `https`, `mailto` and relative targets.
nonisolated struct MarkdownHTMLRenderer: Sendable {
    /// The whole page: a strict content policy, the page style, the rendered body and, with
    /// `eventsPath`, the script that reloads the page when the server says the file changed.
    func document(_ markdown: String, title: String, eventsPath: String?) -> String {
        let reload = eventsPath.map { path in
            "<script>new EventSource(\"\(Self.scriptString(path))\").onmessage=function(e){if(e.data===\"reload\")location.reload()}</script>"
        } ?? ""
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(Self.escape(title))</title>
        <style>\(Self.style)</style></head>
        <body><main>\(body(markdown))</main>\(reload)</body></html>
        """
    }

    /// The rendered blocks only.
    func body(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return "<pre>\(Self.escape(markdown))</pre>"
        }
        var html = ""
        var open: [PresentationIntent.IntentType] = []
        var inCode = false
        for run in parsed.runs {
            let components = Array((run.presentationIntent?.components ?? []).reversed())
            var common = 0
            while common < open.count, common < components.count, open[common].identity == components[common].identity { common += 1 }
            for index in (common..<open.count).reversed() { html += Self.close(open[index].kind, parent: index > 0 ? open[index - 1].kind : nil) }
            open.removeSubrange(common...)
            for component in components[common...] {
                html += Self.open(component.kind, parent: open.last?.kind)
                open.append(component)
            }
            inCode = open.contains { if case .codeBlock = $0.kind { true } else { false } }
            if open.contains(where: { $0.kind == .thematicBreak }) { continue }
            let text = Self.escape(String(parsed[run.range].characters))
            html += inCode ? text : Self.inline(text, run: run)
        }
        for index in open.indices.reversed() { html += Self.close(open[index].kind, parent: index > 0 ? open[index - 1].kind : nil) }
        return html
    }

    private static func inline(_ text: String, run: AttributedString.Runs.Run) -> String {
        var html = text
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.code) { html = "<code>\(html)</code>" }
        if intent.contains(.strikethrough) { html = "<del>\(html)</del>" }
        if intent.contains(.emphasized) { html = "<em>\(html)</em>" }
        if intent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
        if intent.contains(.lineBreak) { html += "<br>" }
        if let link = run.link, let href = safeHref(link) { html = "<a href=\"\(escape(href))\">\(html)</a>" }
        return html
    }

    /// `http`, `https` and `mailto` links, and relative links; nothing else becomes a link.
    static func safeHref(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased() else { return url.relativeString.isEmpty ? nil : url.relativeString }
        return ["http", "https", "mailto"].contains(scheme) ? url.absoluteString : nil
    }

    private static func open(_ kind: PresentationIntent.Kind, parent: PresentationIntent.Kind?) -> String {
        switch kind {
        case .paragraph: "<p>"
        case .header(let level): "<h\(min(max(level, 1), 6))>"
        case .orderedList: "<ol>"
        case .unorderedList: "<ul>"
        case .listItem: "<li>"
        case .codeBlock(let language):
            language.map { "<pre><code class=\"language-\(escape($0))\">" } ?? "<pre><code>"
        case .blockQuote: "<blockquote>"
        case .thematicBreak: "<hr>"
        case .table: "<table>"
        case .tableHeaderRow, .tableRow: "<tr>"
        case .tableCell: parent == .tableHeaderRow ? "<th>" : "<td>"
        @unknown default: "<div>"
        }
    }

    private static func close(_ kind: PresentationIntent.Kind, parent: PresentationIntent.Kind?) -> String {
        switch kind {
        case .paragraph: "</p>"
        case .header(let level): "</h\(min(max(level, 1), 6))>"
        case .orderedList: "</ol>"
        case .unorderedList: "</ul>"
        case .listItem: "</li>"
        case .codeBlock: "</code></pre>"
        case .blockQuote: "</blockquote>"
        case .thematicBreak: ""
        case .table: "</table>"
        case .tableHeaderRow, .tableRow: "</tr>"
        case .tableCell: parent == .tableHeaderRow ? "</th>" : "</td>"
        @unknown default: "</div>"
        }
    }

    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// `text` as the inside of a double-quoted script string, with no way to end the string or the
    /// script element.
    private static func scriptString(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            switch scalar {
            case "\"", "\\", "<", ">", "&", "'": String(format: "\\u%04x", scalar.value)
            default: scalar.value < 0x20 ? String(format: "\\u%04x", scalar.value) : String(scalar)
            }
        }.joined()
    }

    private static let style = """
    :root{color-scheme:light dark;font:16px/1.6 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}
    body{margin:0;padding:32px 20px}main{max-width:72ch;margin:0 auto}
    pre{padding:12px 14px;border-radius:8px;background:rgba(127,127,127,.12);overflow-x:auto}
    code{font:0.875em ui-monospace,"SF Mono",monospace}p code,li code{padding:1px 4px;border-radius:4px;background:rgba(127,127,127,.12)}
    blockquote{margin:0;padding-left:14px;border-left:3px solid rgba(127,127,127,.4);color:rgba(127,127,127,1)}
    table{border-collapse:collapse}th,td{border:1px solid rgba(127,127,127,.35);padding:4px 10px;text-align:left}
    a{color:inherit;text-decoration:underline}hr{border:0;border-top:1px solid rgba(127,127,127,.35)}
    """
}
