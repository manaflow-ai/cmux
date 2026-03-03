import SwiftUI
import AppKit
import WebKit

enum MarkdownPreviewRenderer {
    static let parserMarker = "cmuxLocalMarkdownParserV1"

    private static func localCSS(isDarkMode: Bool) -> String {
        let pageBackground = isDarkMode ? "#0d1117" : "#ffffff"
        let pageText = isDarkMode ? "#f0f6fc" : "#1f2328"
        let mutedText = isDarkMode ? "#9198a1" : "#59636e"
        let border = isDarkMode ? "#3d444d" : "#d1d9e0"
        let altRow = isDarkMode ? "#151b23" : "#f6f8fa"
        let codeBg = isDarkMode ? "#161b22" : "#f6f8fa"
        let inlineCodeBg = isDarkMode ? "#656c7633" : "#afb8c133"
        let link = isDarkMode ? "#58a6ff" : "#0969da"

        return """
        html, body {
          margin: 0;
          padding: 0;
          background: \(pageBackground);
        }
        .canvas {
          padding: 16px 20px 22px 20px;
          background: \(pageBackground);
          box-sizing: border-box;
        }
        .markdown-body {
          box-sizing: border-box;
          min-width: 200px;
          max-width: 980px;
          margin: 0 auto;
          color: \(pageText);
          font-family: -apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans",Helvetica,Arial,sans-serif;
          font-size: 16px;
          line-height: 1.5;
          word-wrap: break-word;
        }
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
          margin-top: 1.5rem;
          margin-bottom: 1rem;
          font-weight: 600;
          line-height: 1.25;
        }
        .markdown-body h1 { font-size: 2em; border-bottom: 1px solid \(border); padding-bottom: 0.3em; }
        .markdown-body h2 { font-size: 1.5em; border-bottom: 1px solid \(border); padding-bottom: 0.3em; }
        .markdown-body p, .markdown-body ul, .markdown-body ol, .markdown-body pre, .markdown-body blockquote, .markdown-body table {
          margin-top: 0;
          margin-bottom: 1rem;
        }
        .markdown-body a { color: \(link); text-decoration: none; }
        .markdown-body a:hover { text-decoration: underline; }
        .markdown-body blockquote {
          margin: 0 0 1rem 0;
          padding: 0 1em;
          color: \(mutedText);
          border-left: 0.25em solid \(border);
        }
        .markdown-body pre {
          padding: 1rem;
          overflow: auto;
          border-radius: 6px;
          background: \(codeBg);
        }
        .markdown-body code, .markdown-body tt {
          color: \(pageText);
          background-color: \(inlineCodeBg);
          border-radius: 6px;
          padding: 0.2em 0.4em;
          font-family: ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;
          font-size: 85%;
        }
        .markdown-body pre code {
          background: transparent;
          padding: 0;
          border-radius: 0;
          font-size: 100%;
        }
        .markdown-body table {
          border-spacing: 0;
          border-collapse: collapse;
          display: block;
          width: max-content;
          max-width: 100%;
          overflow: auto;
        }
        .markdown-body table tr {
          background-color: \(pageBackground);
          border-top: 1px solid \(border);
        }
        .markdown-body table tr:nth-child(2n) { background-color: \(altRow); }
        .markdown-body table th, .markdown-body table td {
          border: 1px solid \(border);
          padding: 6px 13px;
          color: \(pageText) !important;
          background-color: inherit;
        }
        .markdown-body table th *, .markdown-body table td * { color: inherit !important; }
        .fallback {
          white-space: pre-wrap;
          font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
          font-size: 12px;
          color: \(pageText);
        }
        """
    }

    private static let localParserScript = """
    window.\(parserMarker) = true;
    function cmuxEscapeHtml(input) {
      return String(input)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
    }
    function cmuxExtractAllowedTableTags(input) {
      const tags = [];
      const tokenized = String(input).replace(
        /<\\/?(?:table|thead|tbody|tfoot|tr|th|td|caption|colgroup|col)\\b[^>]*>/gi,
        (tag) => {
        const token = `__CMUX_HTML_TAG_${tags.length}__`;
        tags.push(tag);
        return token;
      });
      return { tokenized, tags };
    }
    function cmuxRestoreAllowedTableTags(input, tags) {
      return String(input).replace(/__CMUX_HTML_TAG_(\\d+)__/g, (_, idx) => {
        const i = Number(idx);
        return Number.isNaN(i) ? '' : (tags[i] || '');
      });
    }
    function cmuxSanitizeHref(rawHref) {
      const href = String(rawHref || '').trim();
      if (!href) return '#';
      if (href.startsWith('#') || href.startsWith('/') || href.startsWith('//')) return href;
      if (/^\\.\\.?\\//.test(href)) return href;
      try {
        const parsed = new URL(href, 'https://cmux.local');
        const protocol = parsed.protocol.toLowerCase();
        return (protocol === 'http:' || protocol === 'https:' || protocol === 'mailto:') ? href : '#';
      } catch {
        return '#';
      }
    }
    function cmuxSplitTableRow(row) {
      let value = String(row).trim();
      if (value.startsWith('|')) value = value.slice(1);
      if (value.endsWith('|')) value = value.slice(0, -1);
      return value.split('|').map(cell => cell.trim());
    }
    function cmuxInline(input) {
      const extracted = cmuxExtractAllowedTableTags(input);
      let text = cmuxEscapeHtml(extracted.tokenized);
      text = text.replace(/`([^`\\n]+)`/g, '<code>$1</code>');
      text = text.replace(/\\*\\*([^*\\n]+)\\*\\*/g, '<strong>$1</strong>');
      text = text.replace(/\\*([^*\\n]+)\\*/g, '<em>$1</em>');
      text = text.replace(
        /\\[([^\\]]+)\\]\\(([^\\)\\s]+)\\)/g,
        (_, label, href) => '<a href="' + cmuxEscapeHtml(cmuxSanitizeHref(href)) + '">' + label + '</a>'
      );
      return cmuxRestoreAllowedTableTags(text, extracted.tags);
    }
    function cmuxRenderMarkdown(source) {
      const lines = String(source).replace(/\\r\\n?/g, '\\n').split('\\n');
      const html = [];
      let i = 0;
      const isTableDivider = (line) => /^\\s*\\|?(\\s*:?-{3,}:?\\s*\\|)+\\s*:?-{3,}:?\\s*\\|?\\s*$/.test(line);
      const blockStart = (line) => /^(\\s*$|#{1,6}\\s+|\\s*>|\\s*```|\\s*[-+*]\\s+|\\s*\\d+\\.\\s+)/.test(line);
      const isRawHtmlLine = (line) => /^\\s*<!--.*-->\\s*$/.test(line);
      while (i < lines.length) {
        const line = lines[i];
        if (/^\\s*$/.test(line)) { i++; continue; }
        if (/^\\s*<table(\\s|>)/i.test(line)) {
          const block = [line];
          i++;
          while (i < lines.length) {
            block.push(lines[i]);
            if (/<\\/table>\\s*$/i.test(lines[i])) {
              i++;
              break;
            }
            i++;
          }
          html.push(block.join('\\n'));
          continue;
        }
        if (isRawHtmlLine(line)) {
          const block = [line];
          i++;
          while (i < lines.length && isRawHtmlLine(lines[i])) block.push(lines[i++]);
          html.push(block.join('\\n'));
          continue;
        }
        if (/^\\s*```/.test(line)) {
          i++;
          const code = [];
          while (i < lines.length && !/^\\s*```/.test(lines[i])) code.push(lines[i++]);
          if (i < lines.length) i++;
          html.push('<pre><code>' + cmuxEscapeHtml(code.join('\\n')) + '</code></pre>');
          continue;
        }
        if (line.includes('|') && i + 1 < lines.length && isTableDivider(lines[i + 1])) {
          const headers = cmuxSplitTableRow(line);
          i += 2;
          const rows = [];
          while (i < lines.length && lines[i].includes('|') && !/^\\s*$/.test(lines[i])) rows.push(cmuxSplitTableRow(lines[i++]));
          const thead = '<thead><tr>' + headers.map(h => '<th>' + cmuxInline(h) + '</th>').join('') + '</tr></thead>';
          const tbody = rows.length ? '<tbody>' + rows.map(r => '<tr>' + headers.map((_, idx) => '<td>' + cmuxInline(r[idx] || '') + '</td>').join('') + '</tr>').join('') + '</tbody>' : '';
          html.push('<table>' + thead + tbody + '</table>');
          continue;
        }
        const heading = line.match(/^(#{1,6})\\s+(.*)$/);
        if (heading) {
          const level = heading[1].length;
          html.push('<h' + level + '>' + cmuxInline(heading[2]) + '</h' + level + '>');
          i++;
          continue;
        }
        if (/^\\s*>\\s?/.test(line)) {
          const quote = [];
          while (i < lines.length && /^\\s*>\\s?/.test(lines[i])) quote.push(lines[i++].replace(/^\\s*>\\s?/, ''));
          html.push('<blockquote><p>' + cmuxInline(quote.join(' ')) + '</p></blockquote>');
          continue;
        }
        if (/^\\s*[-+*]\\s+/.test(line) || /^\\s*\\d+\\.\\s+/.test(line)) {
          const ordered = /^\\s*\\d+\\.\\s+/.test(line);
          const items = [];
          while (i < lines.length) {
            const m = lines[i].match(ordered ? /^\\s*\\d+\\.\\s+(.*)$/ : /^\\s*[-+*]\\s+(.*)$/);
            if (!m) break;
            items.push(cmuxInline(m[1]));
            i++;
          }
          const tag = ordered ? 'ol' : 'ul';
          html.push('<' + tag + '>' + items.map(v => '<li>' + v + '</li>').join('') + '</' + tag + '>');
          continue;
        }
        const para = [line.trim()];
        i++;
        while (i < lines.length && !blockStart(lines[i])) para.push(lines[i++].trim());
        html.push('<p>' + cmuxInline(para.join(' ')) + '</p>');
      }
      return html.join('\\n');
    }
    """

    static func renderedHTML(markdown: String, isDarkMode: Bool) -> String {
        let markdownBase64 = Data(markdown.utf8).base64EncodedString()

        return """
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
          \(localCSS(isDarkMode: isDarkMode))
          </style>
          <script>\(localParserScript)</script>
        </head>
        <body>
          <div class="canvas">
            <article id="content" class="markdown-body"></article>
          </div>
          <script>
            function decodeBase64Utf8(b64) {
              const binary = atob(b64);
              const bytes = new Uint8Array(binary.length);
              for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
              return new TextDecoder('utf-8').decode(bytes);
            }

            function render() {
              const host = document.getElementById('content');
              const raw = decodeBase64Utf8('\(markdownBase64)');
              host.innerHTML = cmuxRenderMarkdown(raw);
            }

            try { render(); } catch (e) {
              const host = document.getElementById('content');
              host.classList.add('fallback');
              host.textContent = decodeBase64Utf8('\(markdownBase64)');
            }
          </script>
        </body>
        </html>
        """
    }
}

private struct MarkdownPreviewTextView: NSViewRepresentable {
    let markdown: String

    final class Coordinator {
        var lastRenderedHTML: String?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> CmuxWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        let webView = CmuxWebView(frame: .zero, configuration: configuration)
        let html = MarkdownPreviewRenderer.renderedHTML(markdown: markdown, isDarkMode: resolvedIsDarkMode())
        webView.loadHTMLString(html, baseURL: nil)
        context.coordinator.lastRenderedHTML = html
        return webView
    }

    func updateNSView(_ nsView: CmuxWebView, context: Context) {
        let html = MarkdownPreviewRenderer.renderedHTML(markdown: markdown, isDarkMode: resolvedIsDarkMode())
        guard context.coordinator.lastRenderedHTML != html else { return }
        nsView.loadHTMLString(html, baseURL: nil)
        context.coordinator.lastRenderedHTML = html
    }

    private func resolvedIsDarkMode() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

}

private struct MarkdownEditorTextView: NSViewRepresentable {
    @Binding var text: String
    private let highlighter = MarkdownEditorHighlighter()

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        highlighter.apply(to: textView)
        context.coordinator.lastHighlightedIsDarkMode = isDarkMode(for: textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        let currentIsDarkMode = isDarkMode(for: textView)
        if textView.string != text {
            context.coordinator.isProgrammaticUpdate = true
            textView.string = text
            highlighter.apply(to: textView)
            context.coordinator.isProgrammaticUpdate = false
            context.coordinator.lastHighlightedIsDarkMode = currentIsDarkMode
        } else if context.coordinator.lastHighlightedIsDarkMode != currentIsDarkMode {
            highlighter.apply(to: textView)
            context.coordinator.lastHighlightedIsDarkMode = currentIsDarkMode
        }
    }

    private func isDarkMode(for textView: NSTextView) -> Bool {
        textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditorTextView
        var isProgrammaticUpdate = false
        var lastHighlightedIsDarkMode: Bool?

        init(parent: MarkdownEditorTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate,
                  let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.highlighter.apply(to: textView)
            lastHighlightedIsDarkMode = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }
}

enum MarkdownEditorThemePalette {
    struct TokenHexes: Equatable {
        let heading: String
        let mutedAccent: String
        let emphasis: String
        let link: String
        let code: String
        let codeBackground: String
        let htmlTag: String
        let htmlAttributeName: String
        let htmlAttributeValue: String
        let htmlComment: String
    }

    static func tokenHexes(isDarkMode: Bool) -> TokenHexes {
        if isDarkMode {
            // VS Code Dark+ inspired token colors (widely used default dark editor scheme).
            return TokenHexes(
                heading: "#569CD6",
                mutedAccent: "#9CDCFE",
                emphasis: "#C586C0",
                link: "#569CD6",
                code: "#CE9178",
                codeBackground: "#2D2D2D",
                htmlTag: "#569CD6",
                htmlAttributeName: "#9CDCFE",
                htmlAttributeValue: "#CE9178",
                htmlComment: "#6A9955"
            )
        }
        // VS Code Light+ inspired token colors (widely used default light editor scheme).
        return TokenHexes(
            heading: "#0000FF",
            mutedAccent: "#001080",
            emphasis: "#AF00DB",
            link: "#0451A5",
            code: "#A31515",
            codeBackground: "#F3F3F3",
            htmlTag: "#800000",
            htmlAttributeName: "#FF0000",
            htmlAttributeValue: "#0451A5",
            htmlComment: "#008000"
        )
    }
}

private struct MarkdownEditorHighlighter {
    private let baseFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private let strongFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    private let headingRegex = try? NSRegularExpression(pattern: "(?m)^#{1,6}\\s+.*$")
    private let quoteRegex = try? NSRegularExpression(pattern: "(?m)^\\s{0,3}>\\s?.*$")
    private let listMarkerRegex = try? NSRegularExpression(pattern: "(?m)^\\s{0,3}(?:[-+*]|\\d+\\.)\\s+")
    private let strongRegex = try? NSRegularExpression(pattern: "\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__")
    private let emphasisRegex = try? NSRegularExpression(pattern: "(?<!\\*)\\*[^*\\n]+\\*(?!\\*)|(?<!_)_[^_\\n]+_(?!_)")
    private let linkRegex = try? NSRegularExpression(pattern: "\\[[^\\]]+\\]\\([^\\)]+\\)")
    private let htmlCommentRegex = try? NSRegularExpression(pattern: "<!--(?s).*?-->")
    private let htmlEntityRegex = try? NSRegularExpression(pattern: "&(?:[A-Za-z][A-Za-z0-9]+|#\\d+|#x[0-9A-Fa-f]+);")
    private let tableRowRegex = try? NSRegularExpression(pattern: "(?m)^\\|.*\\|\\s*$")
    private let inlineCodeRegex = try? NSRegularExpression(pattern: "`[^`\\n]+`")
    private let fencedCodeRegex = try? NSRegularExpression(pattern: "(?s)```.*?```")
    private let htmlTagRegex = try? NSRegularExpression(
        pattern: "</?[A-Za-z][A-Za-z0-9:-]*\\b[^>]*?>",
        options: [.dotMatchesLineSeparators]
    )
    private let htmlAttributeRegex = try? NSRegularExpression(
        pattern: "\\b([A-Za-z_:][A-Za-z0-9_:\\-.]*)\\s*=\\s*(\"[^\"]*\"|'[^']*')"
    )

    private struct Palette {
        let headingColor: NSColor
        let mutedAccentColor: NSColor
        let emphasisColor: NSColor
        let linkColor: NSColor
        let codeColor: NSColor
        let codeBackgroundColor: NSColor
        let htmlTagColor: NSColor
        let htmlAttributeNameColor: NSColor
        let htmlAttributeValueColor: NSColor
        let htmlCommentColor: NSColor
    }

    private func palette(for textView: NSTextView) -> Palette {
        let isDarkMode = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let hexes = MarkdownEditorThemePalette.tokenHexes(isDarkMode: isDarkMode)
        return Palette(
            headingColor: NSColor(hex: hexes.heading) ?? .systemBlue,
            mutedAccentColor: NSColor(hex: hexes.mutedAccent) ?? .secondaryLabelColor,
            emphasisColor: NSColor(hex: hexes.emphasis) ?? .systemPurple,
            linkColor: NSColor(hex: hexes.link) ?? .systemBlue,
            codeColor: NSColor(hex: hexes.code) ?? .systemBrown,
            codeBackgroundColor: NSColor(hex: hexes.codeBackground)?.withAlphaComponent(isDarkMode ? 0.55 : 0.9) ?? NSColor.quaternaryLabelColor.withAlphaComponent(0.2),
            htmlTagColor: NSColor(hex: hexes.htmlTag) ?? .systemBlue,
            htmlAttributeNameColor: NSColor(hex: hexes.htmlAttributeName) ?? .secondaryLabelColor,
            htmlAttributeValueColor: NSColor(hex: hexes.htmlAttributeValue) ?? .systemBlue,
            htmlCommentColor: NSColor(hex: hexes.htmlComment) ?? .tertiaryLabelColor
        )
    }

    func apply(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        let text = textView.string as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        let selectedRanges = textView.selectedRanges
        let palette = palette(for: textView)

        textStorage.beginEditing()
        textStorage.setAttributes(
            [
                .font: baseFont,
                .foregroundColor: NSColor.textColor
            ],
            range: fullRange
        )

        applyRegex(headingRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.headingColor,
            .font: strongFont
        ])
        applyRegex(quoteRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.mutedAccentColor
        ])
        applyRegex(listMarkerRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.mutedAccentColor,
            .font: strongFont
        ])
        applyRegex(strongRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.emphasisColor,
            .font: strongFont
        ])
        applyRegex(emphasisRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.emphasisColor
        ])
        applyRegex(linkRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.linkColor
        ])
        applyRegex(htmlCommentRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.htmlCommentColor
        ])
        applyHTMLTagAttributes(in: text, storage: textStorage, palette: palette)
        applyRegex(htmlEntityRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.mutedAccentColor
        ])
        applyRegex(tableRowRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.mutedAccentColor
        ])
        applyRegex(inlineCodeRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.codeColor,
            .backgroundColor: palette.codeBackgroundColor
        ])
        applyRegex(fencedCodeRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.codeColor,
            .backgroundColor: palette.codeBackgroundColor
        ])

        textStorage.endEditing()
        textView.selectedRanges = selectedRanges
    }

    private func applyRegex(
        _ regex: NSRegularExpression?,
        in text: NSString,
        storage: NSTextStorage,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard let regex else { return }
        let range = NSRange(location: 0, length: text.length)
        for match in regex.matches(in: text as String, range: range) {
            storage.addAttributes(attributes, range: match.range)
        }
    }

    private func applyHTMLTagAttributes(
        in text: NSString,
        storage: NSTextStorage,
        palette: Palette
    ) {
        guard let htmlTagRegex, let htmlAttributeRegex else { return }

        let fullRange = NSRange(location: 0, length: text.length)
        for tagMatch in htmlTagRegex.matches(in: text as String, range: fullRange) {
            storage.addAttributes([.foregroundColor: palette.htmlTagColor], range: tagMatch.range)

            let tagText = text.substring(with: tagMatch.range) as NSString
            let localRange = NSRange(location: 0, length: tagText.length)
            for attributeMatch in htmlAttributeRegex.matches(in: tagText as String, range: localRange) {
                guard attributeMatch.numberOfRanges >= 3 else { continue }
                let nameRange = attributeMatch.range(at: 1)
                let valueRange = attributeMatch.range(at: 2)
                let globalNameRange = NSRange(
                    location: tagMatch.range.location + nameRange.location,
                    length: nameRange.length
                )
                let globalValueRange = NSRange(
                    location: tagMatch.range.location + valueRange.location,
                    length: valueRange.length
                )
                storage.addAttributes([.foregroundColor: palette.htmlAttributeNameColor], range: globalNameRange)
                storage.addAttributes([.foregroundColor: palette.htmlAttributeValueColor], range: globalValueRange)
            }
        }
    }
}

struct MarkdownPanelView: View {
    @ObservedObject var panel: MarkdownPanel
    let onRequestPanelFocus: () -> Void

    @State private var saveErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Mode", selection: $panel.isPreviewMode) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

                Spacer(minLength: 8)

                if panel.isDirty {
                    Text("Unsaved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Save") {
                    do {
                        try panel.save()
                    } catch {
                        saveErrorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(panel.fileURL == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Group {
                if panel.isPreviewMode {
                    MarkdownPreviewTextView(markdown: panel.text)
                } else {
                    MarkdownEditorTextView(text: $panel.text)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onRequestPanelFocus()
        }
        .alert("Couldn’t Save Markdown File", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    saveErrorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "Unknown error")
        }
    }
}
